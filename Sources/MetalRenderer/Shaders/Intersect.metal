// ---------------------------------------------------------------------------------------------
// Scene access + ray queries
// ---------------------------------------------------------------------------------------------

// Ray queries. Every kernel reaches the scene through these functions: Metal's instance acceleration structure and
// intersector, or its intersection queries where the traversal hands boxes (far plants' voxels, SDF shapes, virtual
// geometry's clusters) to a loop of ours.
struct Ray {
    float3 origin;
    float3 direction;   // need not be normalized; distances are in units of its length
    float  tmin;
    float  tmax;
};
inline Ray makeRay(float3 origin, float3 direction, float tmin, float tmax) {
    Ray r;
    r.origin = origin; r.direction = direction; r.tmin = tmin; r.tmax = tmax;
    return r;
}

constant uint HIT_NO_CLUSTER = 0xFFFFFFFFu;
constant uint HIT_NO_PART = 0xFFFFFFFFu;
constant uint HIT_VOXEL   = 0xFFFFFFFEu;   // Hit.part: a voxel of a far plant's grid; `primitive` is then its cell's
                                           // low 24 bits (leaf share, normal: FoliageVoxels.swift), barycentrics.x
                                           // the grid's level
constant uint HIT_SDF     = 0xFFFFFFFDu;   // Hit.part: an SDF shape (sdfMarch); `primitive` is then the material
                                           // offset there, barycentrics the normal (instance space, sdfOctEncode;
                                           // intersectClosest only)

struct Hit {
    bool   hit;
    float  distance;
    float2 barycentrics;   // weights of the triangle's 2nd and 3rd vertices
    uint   instance;
    uint   primitive;      // triangle index within the instance's mesh (or within its virtual-geometry cluster)
    uint   cluster;        // this frame's selected virtual-geometry cluster (TraceScene.clusters), or HIT_NO_CLUSTER
    uint   part;           // the part of the instance's assembly (TraceScene.parts), or HIT_NO_PART; `primitive` is
                           // then a triangle of the part's mesh
};

// Far plants as voxel grids (VOXELS: Metal's voxel boxes).
// A plant's voxel grid, for when it is far away (FoliageVoxels.swift).
struct RTVoxels {
    float4 lo;        // xyz = the grid's corner (plant space), w = a level 0 voxel's size
    uint4  dims;      // xyz = level 0 voxels per axis; each next level has half, rounded up; w = 1: an evergreen
    uint4  offsets;   // xyz = where levels 0, 1, 2 start among the cells
};
static_assert(sizeof(RTVoxels) == 48, "RTVoxels: FoliageVoxels.Grid");
constant float VOXEL_DEPTH = 4.0f;   // a cell's 255 = this optical depth across a level 0 voxel
constant uint  VOXEL_LEVELS = 3;
constant float VOXEL_SHADE = 0.62f;  // a voxel's colour over its materials' (traceSurface)

inline float3 rtSafeInverse(float3 d) {
    return 1.0f / select(d, copysign(float3(1e-12f), d), abs(d) < 1e-12f);
}

inline uint3 voxelDims(uint3 d, uint level) { return max((d + ((1u << level) - 1u)) >> level, uint3(1u)); }

// A far plant as its voxel grid: marches level `level` of `g` along o + d t (the plant's space; t as everywhere) a
// voxel at a time and stops in a voxel with the chance that a ray through it meets some of what is in it, so that
// on average the plant covers what its triangles would. Empty stretches are crossed a coarsest-level cell at a
// time. `seed`: the ray's own. True on a hit: h.distance, h.primitive (the cell's leaf share and normal), h.part,
// and the level in h.barycentrics.x. `voxels`: every grid's cells (the offsets in `g` count from there).
// `keep`: the share of its leaves the plant still has (a grid with dims.w set is an evergreen's: all of them).
inline bool rtVoxels(device const uint* voxels, RTVoxels g, uint level, float3 o, float3 d, float3 inv, float3 oi, float tmin,
                     uint seed, float keep, thread Hit& h) {
    float3 lo = g.lo.xyz, hi = lo + float3(g.dims.xyz) * g.lo.w;
    float3 ta = fma(lo, inv, oi), tb = fma(hi, inv, oi);
    float3 tn = min(ta, tb), tf = max(ta, tb);
    float t0 = max(max(tn.x, tn.y), max(tn.z, tmin)), t1 = min(min(tf.x, tf.y), min(tf.z, h.distance));
    if (t0 > t1) return false;
    const uint coarse = VOXEL_LEVELS - 1u;
    uint3 n = voxelDims(g.dims.xyz, level), nc = voxelDims(g.dims.xyz, coarse);
    float size = g.lo.w * float(1u << level), sizeC = g.lo.w * float(1u << coarse);
    device const uint* cells = voxels + g.offsets[level];
    device const uint* cellsC = voxels + g.offsets[coarse];
    float dt = size / length(d);
    float depthScale = VOXEL_DEPTH / 255.0f * float(1u << level);
    float fallen = g.dims.w != 0u ? 0.0f : (1.0f - keep) * (1.0f / 255.0f);
    // Jittered along the ray; a ray that starts inside the grid (a shadow ray from one of its voxels) begins past
    // the voxel it starts in.
    float t = t0 + (float(pcgHash(seed) >> 8) * (1.0f / 16777216.0f) + (t0 > tmin ? 0.0f : 0.75f)) * dt;
    for (uint i = 0; i < 400u && t < t1; ++i) {
        float3 p = max(o + d * t - lo, 0.0f);
        if (level < coarse) {
            uint3 c = min(uint3(p / sizeC), nc - 1u);
            if (cellsC[(c.z * nc.y + c.y) * nc.x + c.x] == 0u) {   // nothing here: on to the far side of this cell
                float3 cl = lo + float3(c) * sizeC;
                float3 e = max(fma(cl, inv, oi), fma(cl + sizeC, inv, oi));
                t = max(t + dt, min(min(e.x, e.y), e.z) + 0.25f * dt);
                continue;
            }
        }
        uint3 v = min(uint3(p / size), n - 1u);
        uint cell = cells[(v.z * n.y + v.y) * n.x + v.x];
        if (cell != 0u) {
            float u = float(pcgHash(seed + (i + 1u) * 0x9E3779B9u) >> 8) * (1.0f / 16777216.0f);
            if (u < 1.0f - exp(-float(cell >> 24) * depthScale * (1.0f - float((cell >> 16) & 0xFFu) * fallen))) {
                h.hit = true;
                h.distance = t;
                h.barycentrics = float2(float(level), 0.0f);
                h.primitive = cell & 0x00FFFFFFu;
                h.cluster = HIT_NO_CLUSTER;
                h.part = HIT_VOXEL;
                return true;
            }
        }
        t += dt;
    }
    return false;
}

// A ray's own seed for a march through instance `id`'s voxels.
inline uint voxelSeed(Ray r, uint id) {
    return pcgHash(as_type<uint>(r.direction.x) ^ pcgHash(as_type<uint>(r.direction.y) ^ pcgHash(as_type<uint>(r.origin.x) + id)));
}
// A virtual instance's BLAS over its current cut (VirtualBLAS.swift): its triangles (p0 p1 p2, w = the debug views'
// IDs in p1.w and p2.w), which Metal's structure over them was built from, and per triangle 3 octahedral normals +
// 3 half2 UVs. A hit's primitive is its place here.
struct VGBlas {
    device const float4*  tris;
    device const uint*    attrs;
    uint                  triangles;   // 0 = no BLAS yet (the instance is masked out)
    uint                  pad0;
    uint                  pad1, pad2;
};
static_assert(sizeof(VGBlas) == 32, "VGBlas: VirtualBLAS.Entry");

// What every ray query and hit reads of the scene (TraceSceneArgs, one per frame slot): Metal's top-level structure
// over the instances, and what a hit reads besides the instance records.
struct TraceScene {
    instance_acceleration_structure tlas;
    device const VGBlas*          vgBlas;     // per virtual instance: its current cut's BLAS (VirtualBLAS.swift)
    device const uint2*           clusters;   // this frame's selected virtual-geometry clusters: (instance, pool
                                              // offset), the cut's (VG_CLUSTERS) or the raster clusters'
    device const float4*          pool;       // streamed virtual-geometry pages (VGStreamer.swift)
    device const struct RTPart*   parts;      // every assembly's parts (FOLIAGE): a part instance's user id names it
    device const MeshData*        meshes;     // the mesh table, and the arrays below: what a leaf card's alpha test
                                              // reads (ALPHA_TEST)
    float4                        wind;       // xy = where the wind blows to (world x, z; unit), z = strength (0 =
                                              // still), w = gustiness
    float4                        windTime;   // x = this frame's time (s), y = the last frame's, w = the share of the
                                              // leaves that have fallen (the season)
    device const uchar*           cutouts;    // leaf cards' alpha layers, CUTOUT_SIZE squared each (ALPHA_TEST)
    uint                          clusterInstance;   // VG_CLUSTERS: the instance whose boxes are the cut's clusters
    uint                          pad;
    device atomic_uint*           stats;      // RT_STATS builds: rays, triangle candidates, box candidates
    device const uint*            indices;
    device const float2*          uvs;
};
static_assert(sizeof(TraceScene) == 128 && __builtin_offsetof(TraceScene, stats) == 96 && __builtin_offsetof(TraceScene, uvs) == 112,
              "TraceScene: TraceSceneArgs.write writes these offsets");

// RT_STATS (Pipelines.compile, the Debug window's counters): every query counts its ray and the candidates Metal's
// traversal hands it, the triangles made non-opaque for it (TraversalStats). Slower, and only for the counts.
#ifndef RT_STATS
#define RT_STATS 0
#endif

#define SCENE_ACCEL constant TraceScene&

// A virtual-geometry cluster's data in the pool (VirtualGeometryBuilder.clusterBlob): header (2 x uint4), BVH
// nodes, vertices (position + octahedral normal), UVs (half2), triangles (three 8-bit local indices).
// A node holds both children's boxes; a child ref with bit 31 set is a leaf: (count - 1) << 28 | first triangle.
struct BVHNode {
    float4 lo0;   // xyz = child 0 box min, w = child 0 ref (bits)
    float4 hi0;   // xyz = child 0 box max
    float4 lo1;
    float4 hi1;
};
constant uint BVH_LEAF = 0x80000000u;
constant uint BVH_NONE = 0xFFFFFFFFu;

struct VGClusterView {
    device const BVHNode* nodes;
    device const float4*  positions;   // xyz, w = octahedral normal bits
    device const uint*    uvs;
    device const uint*    tris;
};
inline VGClusterView vgClusterView(device const float4* blob) {
    uint4 offsets = ((device const uint4*)blob)[1];   // bytes: nodes, positions, UVs, triangles
    device const uchar* base = (device const uchar*)blob;
    VGClusterView v;
    v.nodes = (device const BVHNode*)(base + offsets.x);
    v.positions = (device const float4*)(base + offsets.y);
    v.uvs = (device const uint*)(base + offsets.z);
    v.tris = (device const uint*)(base + offsets.w);
    return v;
}
inline float3 octDecode(uint bits) {
    float2 e = float2(as_type<short2>(bits)) / 32767.0f;
    float3 n = float3(e, 1.0f - abs(e.x) - abs(e.y));
    if (n.z < 0.0f) n.xy = (1.0f - abs(n.yx)) * select(float2(-1.0f), float2(1.0f), n.xy >= 0.0f);
    return normalize(n);
}

// Slab test of a box against [tmin, tmax]; tnear = entry distance.
inline bool rtSlab(float3 lo, float3 hi, float3 inv, float3 oi, float tmin, float tmax, thread float& tnear) {
    float3 t0 = fma(lo, inv, oi), t1 = fma(hi, inv, oi);
    float3 tn = min(t0, t1), tf = max(t0, t1);
    tnear = max(max(tn.x, tn.y), max(tn.z, tmin));
    return tnear <= min(min(tf.x, tf.y), min(tf.z, tmax));
}

// Möller-Trumbore, both faces: true on a hit nearer than `tmax`, at `t` with barycentrics `uv`.
inline bool rtTriangle(float3 o, float3 d, float3 p0, float3 p1, float3 p2, float tmin, float tmax, thread float& t, thread float2& uv) {
    float3 e1 = p1 - p0, e2 = p2 - p0;
    float3 pv = cross(d, e2);
    float det = dot(e1, pv);
    if (det == 0.0f) return false;
    float inv = 1.0f / det;
    float3 tv = o - p0;
    float u = dot(tv, pv) * inv;
    if (u < 0.0f || u > 1.0f) return false;
    float3 qv = cross(tv, e1);
    float v = dot(d, qv) * inv;
    if (v < 0.0f || u + v > 1.0f) return false;
    float h = dot(e2, qv) * inv;
    if (h < tmin || h > tmax) return false;
    t = h;
    uv = float2(u, v);
    return true;
}

// The nearest hit with a cluster's triangles, through its own small BVH (object space): its triangle in `h`.
inline bool clusterWalk(VGClusterView view, float3 o, float3 d, float tmin, bool any, thread Hit& h) {
    float3 inv = rtSafeInverse(d), oi = -o * inv;
    uint stack[16];
    uint sp = 0, ref = 0;
    bool found = false;
    while (true) {
        if ((ref & BVH_LEAF) == 0) {
            BVHNode n = view.nodes[ref];
            float t0, t1;
            bool b0 = rtSlab(n.lo0.xyz, n.hi0.xyz, inv, oi, tmin, h.distance, t0);
            bool b1 = rtSlab(n.lo1.xyz, n.hi1.xyz, inv, oi, tmin, h.distance, t1);
            uint c0 = as_type<uint>(n.lo0.w), c1 = as_type<uint>(n.lo1.w);
            if (b0 && b1) {
                bool swap = t1 < t0;
                if (sp < 16) stack[sp++] = swap ? c0 : c1;
                ref = swap ? c1 : c0;
                continue;
            }
            if (b0 || b1) { ref = b0 ? c0 : c1; continue; }
        } else if (ref != BVH_NONE) {   // BVH_NONE: the empty child of a single-leaf cluster
            uint first = ref & 0x0FFFFFFFu, end = first + ((ref >> 28) & 7u) + 1u;
            for (uint t = first; t < end; ++t) {
                uint packed = view.tris[t];
                float3 p0 = view.positions[packed & 0xFFu].xyz, p1 = view.positions[(packed >> 8) & 0xFFu].xyz;
                float3 p2 = view.positions[(packed >> 16) & 0xFFu].xyz;
                float tt;
                float2 uv;
                if (rtTriangle(o, d, p0, p1, p2, tmin, h.distance, tt, uv)) {
                    h.hit = true;
                    h.distance = tt;
                    h.barycentrics = uv;
                    h.primitive = t;
                    found = true;
                    if (any) return true;
                }
            }
        }
        if (sp == 0) return found;
        ref = stack[--sp];
    }
}

// VOXEL_BOXES: a far plant's wood instance is a box, one per grid and level (VoxelGrids.swift), whose primitive data
// names the grid and the level, and its leaf instance is masked out (VoxelLOD.swift). The ray queries are then
// intersection queries: the traversal hands the loop each box it meets, which rtVoxels marches; triangles stay the
// traversal's own (opaque: never handed to the loop). A voxel hit is kept here and never committed to the query:
// commit_bounding_box_intersection costs far more than the candidates the shorter ray would save (M4 Max, the open
// world's road views: 25-30 ms a frame committing, 9-12 ms not).
struct VoxelBox {
    device const RTVoxels* grid;
    device const uint*     cells;   // every grid's cells (the grid's offsets count from here)
    uint level;
    uint pad0, pad1, pad2;
};
static_assert(sizeof(VoxelBox) == 32, "VoxelBox: VoxelGrids.BoxData");

// SDF_SHAPES: an SDF shape's instance is a box too, the shape's (SDFBuffers.swift), which the loop marches (sdfMarch).
// Its data is laid out as a voxel box's, `tag` where a voxel box has its level: what tells the two apart.
constant uint SDF_BOX_TAG = 0xFFFFFFFFu;
struct SDFBox {
    device const SDFScene* scene;
    uint shape;
    uint pad0;
    uint tag;                       // SDF_BOX_TAG
    uint pad1, pad2, pad3;
};
static_assert(sizeof(SDFBox) == 32 && __builtin_offsetof(SDFBox, tag) == __builtin_offsetof(VoxelBox, level), "SDFBox: SDFBuffers.BoxData");

// VG_CLUSTERS: this frame's selected clusters, each a box in world space (vgBoxesKernel), all in one instance
// (TraceScene.clusterInstance): the loop walks the cluster's own BVH in its instance's space.
struct ClusterBox {
    float4 row0;   // world -> object rows of the cluster's instance
    float4 row1;
    float4 row2;
    uint   index;  // into TraceScene.clusters
    uint   mask;   // its instance's
    uint   pad0, pad1;
};
static_assert(sizeof(ClusterBox) == 64, "ClusterBox: VirtualGeometry.boxDataStride");

// The scene has boxes (far plants' voxels, SDF shapes, the cut's clusters) or leaf cards: the ray queries are
// intersection queries, whose loop gets them.
constant bool QUERY_LOOP = VOXEL_BOXES || SDF_SHAPES || VG_CLUSTERS || ALPHA_TEST;

// Rays that meet the scene's geometry meet the voxel boxes too.
inline uint voxelMask(uint mask) { return VOXEL_BOXES && (mask & MASK_GEOMETRY) != 0 ? mask | MASK_VOXELS : mask; }

inline intersection_params voxelParams(bool any) {
    intersection_params p;
    p.assume_geometry_type(geometry_type::triangle | geometry_type::bounding_box);
    p.accept_any_intersection(any);
    return p;
}

// No box hit yet: what the query loops start `v` from.
inline Hit voxelMiss(Ray r) {
    Hit v;
    v.hit = false;
    v.distance = r.tmax;
    return v;
}

constant uint CUTOUT_SIZE = 512;   // a leaf-card alpha layer's side (FoliageTextures.cardSheetSize)

// A leaf card is there only where its picture is: triangle `prim` of `mesh` at barycentrics `bc` against the mesh's
// alpha layer (MeshData.cutout: the layer + 1 in the top byte, the first card triangle below it; the ones before it
// are wood).
inline bool rtCutout(SCENE_ACCEL sc, uint mesh, uint prim, float2 bc) {
    MeshData m = sc.meshes[mesh];
    uint layer = m.cutout >> 24;
    if (layer == 0u || prim < (m.cutout & 0xFFFFFFu)) return true;
    float2 uv = float2(0.0f);
    float w[3] = {1.0f - bc.x - bc.y, bc.x, bc.y};
    for (uint k = 0; k < 3; ++k) {
        float2 t;
        if (STREAMED && m.block != nullptr) {   // a mesh in a buffer of its own: positions, normals, UVs, indices
            device const float2* uvs = (device const float2*)(m.block + 2u * m.vertexCount);
            device const uint* indices = (device const uint*)(uvs + m.vertexCount);
            t = uvs[indices[prim * 3u + k]];
        } else {
            t = sc.uvs[sc.indices[m.firstIndex + prim * 3u + k]];
        }
        uv += t * w[k];
    }
    uint2 texel = min(uint2(max(uv, 0.0f) * float(CUTOUT_SIZE)), uint2(CUTOUT_SIZE - 1u));
    return sc.cutouts[((layer - 1u) * CUTOUT_SIZE + texel.y) * CUTOUT_SIZE + texel.x] != 0;
}

// The queries' types and what a hit names, by how deep the instances go. FOLIAGE scenes have three levels (multi-level
// instancing, PlantTracing.swift): a plant's instance names one of its assembly's variants, an instance structure
// whose instances are the plant's parts, each with the part's number as its user id. Every other scene has two.
// A hit's instance is always the top level's (TILED: its user id).
template <bool PLANTS> struct Levels;
template <> struct Levels<false> {
    typedef intersection_query<triangle_data, instancing> Closest;
    typedef intersection_query<instancing> Plain;
    typedef intersector<triangle_data, instancing> ClosestIntersector;
    typedef intersector<instancing> PlainIntersector;
    template <typename Q> static uint candidate(thread Q& q) { return TILED ? q.get_candidate_user_instance_id() : q.get_candidate_instance_id(); }
    template <typename Q> static uint candidateIndex(thread Q& q) { return q.get_candidate_instance_id(); }
    template <typename Q> static uint candidatePart(thread Q& q) { return HIT_NO_PART; }
    template <typename Q> static uint committed(thread Q& q) { return TILED ? q.get_committed_user_instance_id() : q.get_committed_instance_id(); }
    template <typename Q> static uint committedPart(thread Q& q) { return HIT_NO_PART; }
    template <typename R> static uint instance(thread const R& r) { return TILED ? r.user_instance_id : r.instance_id; }
    template <typename R> static uint part(thread const R& r) { return HIT_NO_PART; }
    template <typename Q> static bool card(thread Q& q, SCENE_ACCEL sc) { return true; }   // (no plants, no cards)
};
template <> struct Levels<true> {
    typedef intersection_query<triangle_data, instancing, max_levels<3>> Closest;
    typedef Closest Plain;   // (the cards' alpha test reads the candidate's barycentrics)
    typedef intersector<triangle_data, instancing, max_levels<3>> ClosestIntersector;
    typedef intersector<instancing, max_levels<3>> PlainIntersector;
    template <typename Q> static uint candidate(thread Q& q) { return TILED ? q.get_candidate_user_instance_id(0) : q.get_candidate_instance_id(0); }
    template <typename Q> static uint candidateIndex(thread Q& q) { return q.get_candidate_instance_id(0); }
    template <typename Q> static uint candidatePart(thread Q& q) {
        return q.get_candidate_instance_count() > 1 ? q.get_candidate_user_instance_id(1) : HIT_NO_PART;
    }
    template <typename Q> static uint committed(thread Q& q) { return TILED ? q.get_committed_user_instance_id(0) : q.get_committed_instance_id(0); }
    template <typename Q> static uint committedPart(thread Q& q) {
        return q.get_committed_instance_count() > 1 ? q.get_committed_user_instance_id(1) : HIT_NO_PART;
    }
    template <typename R> static uint instance(thread const R& r) { return TILED ? r.user_instance_id[0] : r.instance_id[0]; }
    template <typename R> static uint part(thread const R& r) { return r.instance_count > 1 ? r.user_instance_id[1] : HIT_NO_PART; }
    // The candidate triangle (only leaf cards' aren't opaque): true if the ray meets it there.
    template <typename Q> static bool card(thread Q& q, SCENE_ACCEL sc) {
        uint part = candidatePart(q);
        if (part == HIT_NO_PART) return true;
        return rtCutout(sc, sc.parts[part].mesh, q.get_candidate_primitive_id(), q.get_candidate_triangle_barycentric_coord());
    }
};

// The query's candidate box: marched (or walked) as far as the nearest hit so far, `v`'s or the triangle the query
// has committed. True if the ray stops in it: `v` is then that hit (its distance, instance, and a voxel's cell and
// level, a shape's material and, with `normal`, normal, or a cluster's triangle).
template <bool PLANTS, typename Q>
inline bool boxCandidate(thread Q& q, Ray r, uint mask, bool normal, SCENE_ACCEL sc, thread Hit& v) {
    float3 o = q.get_candidate_ray_origin(), d = q.get_candidate_ray_direction();
    float tmax = q.get_committed_intersection_type() == intersection_type::none ? v.distance : min(v.distance, q.get_committed_distance());
    if (VG_CLUSTERS && Levels<PLANTS>::candidateIndex(q) == sc.clusterInstance) {
        device const ClusterBox& box = *(device const ClusterBox*)q.get_candidate_primitive_data();
        if ((box.mask & mask) == 0) return false;
        uint2 rc = sc.clusters[box.index];
        float4 o4 = float4(o, 1.0f), d4 = float4(d, 0.0f);   // the instance is the identity: o, d are the world's
        float3 oo = float3(dot(box.row0, o4), dot(box.row1, o4), dot(box.row2, o4));
        float3 od = float3(dot(box.row0, d4), dot(box.row1, d4), dot(box.row2, d4));
        Hit c;
        c.hit = false;
        c.distance = tmax;
        if (!clusterWalk(vgClusterView(sc.pool + rc.y), oo, od, r.tmin, !normal, c)) return false;
        v = c;
        v.instance = rc.x;
        v.cluster = box.index;
        v.part = HIT_NO_PART;
        return true;
    }
    device const VoxelBox& box = *(device const VoxelBox*)q.get_candidate_primitive_data();
    uint id = Levels<PLANTS>::candidate(q);
    if (SDF_SHAPES && box.level == SDF_BOX_TAG) {
        device const SDFBox& shape = *(device const SDFBox*)&box;
        float t;
        float2 n = float2(0.0f);
        uint material, steps = 0;
        if (!sdfMarch(*shape.scene, shape.shape, o, d, r.tmin, tmax, length(r.direction), normal, t, n, material, steps)) return false;
        v.hit = true;
        v.distance = t;
        v.barycentrics = n;
        v.primitive = material;
        v.cluster = HIT_NO_CLUSTER;
        v.part = HIT_SDF;
        v.instance = id;
        return true;
    }
    if (!VOXEL_BOXES) return false;
    float3 inv = rtSafeInverse(d);
    Hit c;
    c.hit = false;
    c.distance = tmax;
    // An assembly's grid in autumn: the share of its leaves the plant still has (its triangles' variant has as many).
    float keep = FOLIAGE && sc.windTime.w > 0.0f ? plantKeep(sc.windTime.w, id) : 1.0f;
    if (!rtVoxels(box.cells, *box.grid, box.level, o, d, inv, -o * inv, r.tmin, voxelSeed(r, id), keep, c)) return false;
    v = c;
    v.instance = id;
    return true;
}

// One candidate of a query's loop: a leaf card's triangle (committed where its picture is) or a box. True if the
// query may stop (ANY: a hit).
template <bool PLANTS, bool ANY, typename Q>
inline bool candidate(thread Q& q, Ray r, uint mask, bool normal, SCENE_ACCEL sc, thread Hit& v) {
    if (ALPHA_TEST && q.get_candidate_intersection_type() == intersection_type::triangle) {
        if (!Levels<PLANTS>::card(q, sc)) return false;
        if (q.get_committed_intersection_type() == intersection_type::none
            || q.get_candidate_triangle_distance() < q.get_committed_distance()) q.commit_triangle_intersection();
        return ANY;
    }
    return boxCandidate<PLANTS>(q, r, mask, normal, sc, v) && ANY;
}

// The query's committed triangle, or the box loop's nearer hit `v`.
template <bool PLANTS, typename Q>
inline Hit queryHit(thread Q& q, Hit v) {
    // The nearer of the box's hit and the query's triangle (a box's is only ever kept in front of the triangle
    // committed by then, but a nearer triangle may have come after it).
    bool triangle = q.get_committed_intersection_type() == intersection_type::triangle;
    if (v.hit && !(triangle && q.get_committed_distance() < v.distance)) return v;   // HIT_VOXEL, HIT_SDF or a cluster
    Hit h;
    h.hit = triangle;
    h.distance = triangle ? q.get_committed_distance() : INFINITY;
    h.barycentrics = triangle ? q.get_committed_triangle_barycentric_coord() : float2(0.0f);
    h.instance = Levels<PLANTS>::committed(q);
    h.primitive = q.get_committed_primitive_id();
    h.cluster = HIT_NO_CLUSTER;
    h.part = triangle ? Levels<PLANTS>::committedPart(q) : HIT_NO_PART;
    return h;
}

// A query that counts what Metal's traversal hands it (`n`: triangles, boxes), every triangle made non-opaque for it
// so that it does: the "Traversal cost" view and RT_STATS builds. The same hit as the queries below (the nearest
// candidate is committed, a leaf card's where its picture is; ANY: the first).
template <bool PLANTS, bool ANY>
inline Hit countedQuery(Ray r, uint mask, SCENE_ACCEL sc, thread uint2& n) {
    typename Levels<PLANTS>::Closest q;
    intersection_params p = voxelParams(ANY);
    p.force_opacity(forced_opacity::non_opaque);
    q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, voxelMask(mask), p);
    Hit v = voxelMiss(r);
    n = uint2(0u);
    while (q.next()) {
        if (q.get_candidate_intersection_type() == intersection_type::triangle) {
            ++n.x;
            if (ALPHA_TEST && !Levels<PLANTS>::card(q, sc)) continue;
            if (q.get_committed_intersection_type() == intersection_type::none
                || q.get_candidate_triangle_distance() < q.get_committed_distance()) q.commit_triangle_intersection();
            if (ANY) break;
        } else {
            ++n.y;
            if (boxCandidate<PLANTS>(q, r, mask, !ANY, sc, v) && ANY) break;
        }
    }
    return queryHit<PLANTS>(q, v);
}

// Closest hit, counting the candidates on the way (`countedQuery`): the "Traversal cost" view only.
Hit intersectClosestCost(Ray r, uint mask, SCENE_ACCEL sc, thread uint& candidates) {
    uint2 n;
    Hit h = FOLIAGE ? countedQuery<true, false>(r, mask, sc, n) : countedQuery<false, false>(r, mask, sc, n);
    candidates = n.x + n.y;
    return h;
}

#if RT_STATS
template <bool ANY>
inline Hit countedHit(Ray r, uint mask, SCENE_ACCEL sc) {
    uint2 n;
    Hit h = FOLIAGE ? countedQuery<true, ANY>(r, mask, sc, n) : countedQuery<false, ANY>(r, mask, sc, n);
    atomic_fetch_add_explicit(&sc.stats[0], 1u, memory_order_relaxed);
    atomic_fetch_add_explicit(&sc.stats[1], n.x, memory_order_relaxed);
    atomic_fetch_add_explicit(&sc.stats[2], n.y, memory_order_relaxed);
    return h;
}
#endif

template <bool PLANTS>
inline Hit closestHit(Ray r, uint mask, SCENE_ACCEL sc) {
    if (QUERY_LOOP) {
        typename Levels<PLANTS>::Closest q;
        q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, voxelMask(mask), voxelParams(false));
        Hit v = voxelMiss(r);
        while (q.next()) candidate<PLANTS, false>(q, r, mask, true, sc, v);
        return queryHit<PLANTS>(q, v);
    }
    typename Levels<PLANTS>::ClosestIntersector isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, mask);
    Hit h;
    h.hit = res.type == intersection_type::triangle;
    h.distance = res.distance;
    h.barycentrics = res.triangle_barycentric_coord;
    h.instance = Levels<PLANTS>::instance(res);   // TILED: its id (SceneBuffers' descriptors)
    h.primitive = res.primitive_id;
    h.cluster = HIT_NO_CLUSTER;
    h.part = h.hit ? Levels<PLANTS>::part(res) : HIT_NO_PART;
    return h;
}

Hit intersectClosest(Ray r, uint mask, SCENE_ACCEL sc) {
#if RT_STATS
    return countedHit<false>(r, mask, sc);
#endif
    return FOLIAGE ? closestHit<true>(r, mask, sc) : closestHit<false>(r, mask, sc);
}

template <bool PLANTS>
inline float closestDistance(Ray r, uint mask, SCENE_ACCEL sc) {
    if (QUERY_LOOP) {
        typename Levels<PLANTS>::Plain q;
        q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, voxelMask(mask), voxelParams(false));
        Hit v = voxelMiss(r);
        while (q.next()) candidate<PLANTS, false>(q, r, mask, false, sc, v);
        float t = q.get_committed_intersection_type() == intersection_type::none ? INFINITY : q.get_committed_distance();
        return v.hit ? min(v.distance, t) : t;
    }
    typename Levels<PLANTS>::PlainIntersector isect;   // no triangle_data: barycentrics aren't needed
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, mask);
    return res.type == intersection_type::none ? INFINITY : res.distance;
}

// Closest hit distance only (INFINITY if none).
float intersectDistance(Ray r, uint mask, SCENE_ACCEL sc) {
#if RT_STATS
    Hit h = countedHit<false>(r, mask, sc);
    return h.hit ? h.distance : INFINITY;
#endif
    return FOLIAGE ? closestDistance<true>(r, mask, sc) : closestDistance<false>(r, mask, sc);
}

template <bool PLANTS>
inline bool anyHit(Ray r, uint mask, SCENE_ACCEL sc, thread float& t) {
    if (QUERY_LOOP) {
        typename Levels<PLANTS>::Plain q;
        q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, voxelMask(mask), voxelParams(true));
        Hit v = voxelMiss(r);
        while (q.next()) {
            if (candidate<PLANTS, true>(q, r, mask, false, sc, v)) {   // any hit will do
                if (v.hit) { t = v.distance; return true; }
                break;
            }
        }
        bool hit = q.get_committed_intersection_type() != intersection_type::none;
        t = hit ? q.get_committed_distance() : r.tmax;
        return hit;
    }
    typename Levels<PLANTS>::PlainIntersector isect;
    isect.assume_geometry_type(geometry_type::triangle);
    isect.force_opacity(forced_opacity::opaque);
    isect.accept_any_intersection(true);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), sc.tlas, mask);
    t = res.distance;
    return res.type != intersection_type::none;
}

// Any hit (shadow rays): true if something is in the way; `t` = its distance.
bool intersectAny(Ray r, uint mask, SCENE_ACCEL sc, thread float& t) {
#if RT_STATS
    Hit h = countedHit<true>(r, mask, sc);
    t = h.hit ? h.distance : r.tmax;
    return h.hit;
#endif
    return FOLIAGE ? anyHit<true>(r, mask, sc, t) : anyHit<false>(r, mask, sc, t);
}
