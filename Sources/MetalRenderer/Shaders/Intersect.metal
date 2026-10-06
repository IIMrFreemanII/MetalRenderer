// ---------------------------------------------------------------------------------------------
// Scene access + ray queries
// ---------------------------------------------------------------------------------------------

// Ray queries. Every kernel reaches the scene through these three functions, implemented twice:
//   CUSTOM_RT = 0: Metal's instance acceleration structure and intersector;
//   CUSTOM_RT = 1: this file's two-level BVH (see "Custom BVH traversal").
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
constant uint HIT_CURVE   = 0xFFFFFFFCu;   // Hit.part: a strand's curve (HAIR_CURVES); `primitive` is then its segment,
                                           // barycentrics.x the curve's parameter along it

struct Hit {
    bool   hit;
    float  distance;
    float2 barycentrics;   // weights of the triangle's 2nd and 3rd vertices
    uint   instance;
    uint   primitive;      // triangle index within the instance's mesh (or within its virtual-geometry cluster)
    uint   cluster;        // custom tracer: this frame's selected virtual-geometry cluster, or HIT_NO_CLUSTER
    uint   part;           // custom tracer: the part of the instance's assembly (RTScene.parts), or HIT_NO_PART;
                           // `primitive` is then a triangle of the part's mesh
};

// Far plants as voxel grids (VOXELS: the custom tracer's assemblies, or Metal's voxel boxes): shared by both tracers.
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

#if !CUSTOM_RT

#define SCENE_ACCEL instance_acceleration_structure

// VOXEL_BOXES (Metal's tracer): a far plant's wood instance is a box, one per grid and level (VoxelGrids.swift),
// whose primitive data names the grid and the level, and its leaf instance is masked out (VoxelLOD.swift). The ray
// queries are then intersection queries: the traversal hands the loop each box it meets, which rtVoxels marches;
// triangles stay the traversal's own (opaque: never handed to the loop). A voxel hit is kept here and never
// committed to the query: commit_bounding_box_intersection costs far more than the candidates the shorter ray would
// save (M4 Max, the open world's road views: 25-30 ms a frame committing, 9-12 ms not).
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

// The scene has boxes (far plants' voxels, SDF shapes): the ray queries are intersection queries, whose loop gets them.
constant bool QUERY_LOOP = VOXEL_BOXES || SDF_SHAPES;

// Rays that meet the scene's geometry meet the voxel boxes too.
inline uint voxelMask(uint mask) { return VOXEL_BOXES && (mask & MASK_GEOMETRY) != 0 ? mask | MASK_VOXELS : mask; }

inline intersection_params voxelParams(bool any) {
    intersection_params p;
    p.assume_geometry_type(geometry_type::triangle | geometry_type::bounding_box);
    p.accept_any_intersection(any);
    return p;
}

// No voxel hit yet: what the query loops start `v` from.
inline Hit voxelMiss(Ray r) {
    Hit v;
    v.hit = false;
    v.distance = r.tmax;
    return v;
}

// The query's candidate box: marched as far as the nearest hit so far, `v`'s or the triangle the query has
// committed. True if the ray stops in it: `v` is then that hit (its distance, instance, and a voxel's cell and level
// or a shape's material and, with `normal`, normal).
template <typename Q>
inline bool boxCandidate(thread Q& q, Ray r, bool normal, thread Hit& v) {
    device const VoxelBox& box = *(device const VoxelBox*)q.get_candidate_primitive_data();
    uint id = TILED ? q.get_candidate_user_instance_id() : q.get_candidate_instance_id();
    float3 o = q.get_candidate_ray_origin(), d = q.get_candidate_ray_direction();
    float tmax = q.get_committed_intersection_type() == intersection_type::none ? v.distance : min(v.distance, q.get_committed_distance());
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
    if (!rtVoxels(box.cells, *box.grid, box.level, o, d, inv, -o * inv, r.tmin, voxelSeed(r, id), 1.0f, c)) return false;
    v = c;
    v.instance = id;
    return true;
}

// HAIR_CURVES: the queries meet the strands' curves too (round Catmull-Rom segments of 4 control points, opaque),
// which only queries with curve_data may. A curve's hit is HIT_CURVE with the curve's parameter in barycentrics.x
// (traceSurface finds the point there). The overloads pick out the queries that have them.
#if HAS_CURVES
inline bool isCurveHit(intersection_type t) { return t == intersection_type::curve; }
template <typename Q> inline float committedCurve(thread Q& q) { return 0.0f; }
inline float committedCurve(thread intersection_query<triangle_data, curve_data, instancing>& q) { return q.get_committed_curve_parameter(); }
template <typename R> inline float resultCurve(thread const R& res) { return 0.0f; }
inline float resultCurve(thread const intersection_result<triangle_data, curve_data, instancing>& res) { return res.curve_parameter; }
inline void assumeCurves(thread intersection_params& p) {
    p.assume_curve_type(curve_type::round);
    p.assume_curve_basis(curve_basis::catmull_rom);
    p.assume_curve_control_point_count(4);
}
template <typename I> inline void assumeCurves(thread I& isect) {
    isect.assume_curve_type(curve_type::round);
    isect.assume_curve_basis(curve_basis::catmull_rom);
    isect.assume_curve_control_point_count(4);
}
#else
inline bool isCurveHit(intersection_type t) { return false; }
template <typename Q> inline float committedCurve(thread Q& q) { return 0.0f; }
template <typename R> inline float resultCurve(thread const R& res) { return 0.0f; }
#endif

// What a query is told it meets: triangles, the boxes of its loop (`boxes`), and the curves.
inline geometry_type queryGeometry(bool boxes) {
    geometry_type g = boxes ? geometry_type::triangle | geometry_type::bounding_box : geometry_type::triangle;
#if HAS_CURVES
    if (HAIR_CURVES) g = g | geometry_type::curve;
#endif
    return g;
}

inline intersection_params queryParams(bool any) {
    intersection_params p = voxelParams(any);
    p.assume_geometry_type(queryGeometry(true));
#if HAS_CURVES
    if (HAIR_CURVES) assumeCurves(p);
#endif
    return p;
}

template <typename Q>
inline Hit queryClosest(Ray r, uint mask, SCENE_ACCEL accel) {
    Q q;
    q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), accel, voxelMask(mask), queryParams(false));
    Hit v = voxelMiss(r);
    while (q.next()) boxCandidate(q, r, true, v);
    // The nearer of the box's hit and the query's triangle or curve (a box's is only ever kept in front of what was
    // committed by then, but a nearer one may have come after it).
    intersection_type type = q.get_committed_intersection_type();
    bool triangle = type == intersection_type::triangle, curve = isCurveHit(type);
    if (v.hit && !((triangle || curve) && q.get_committed_distance() < v.distance)) return v;   // HIT_VOXEL or HIT_SDF
    Hit h;
    h.hit = triangle || curve;
    h.distance = h.hit ? q.get_committed_distance() : INFINITY;
    h.barycentrics = triangle ? q.get_committed_triangle_barycentric_coord() : float2(curve ? committedCurve(q) : 0.0f, 0.0f);
    h.instance = TILED ? q.get_committed_user_instance_id() : q.get_committed_instance_id();
    h.primitive = q.get_committed_primitive_id();
    h.cluster = HIT_NO_CLUSTER;
    h.part = curve ? HIT_CURVE : HIT_NO_PART;
    return h;
}

template <typename I>
inline Hit intersectorClosest(thread I& isect, Ray r, uint mask, SCENE_ACCEL accel) {
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    bool curve = isCurveHit(res.type);
    Hit h;
    h.hit = res.type == intersection_type::triangle || curve;
    h.distance = res.distance;
    h.barycentrics = curve ? float2(resultCurve(res), 0.0f) : res.triangle_barycentric_coord;
    h.instance = TILED ? res.user_instance_id : res.instance_id;   // TILED: its id (SceneBuffers' descriptors)
    h.primitive = res.primitive_id;
    h.cluster = HIT_NO_CLUSTER;
    h.part = curve ? HIT_CURVE : HIT_NO_PART;
    return h;
}

Hit intersectClosest(Ray r, uint mask, SCENE_ACCEL accel) {
#if HAS_CURVES
    if (HAIR_CURVES) {
        if (QUERY_LOOP) return queryClosest<intersection_query<triangle_data, curve_data, instancing>>(r, mask, accel);
        intersector<triangle_data, curve_data, instancing> isect;
        isect.assume_geometry_type(queryGeometry(false));
        assumeCurves(isect);
        return intersectorClosest(isect, r, mask, accel);
    }
#endif
    if (QUERY_LOOP) return queryClosest<intersection_query<triangle_data, instancing>>(r, mask, accel);
    intersector<triangle_data, instancing> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    return intersectorClosest(isect, r, mask, accel);
}

template <typename Q>
inline float queryDistance(Ray r, uint mask, SCENE_ACCEL accel) {
    Q q;
    q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), accel, voxelMask(mask), queryParams(false));
    Hit v = voxelMiss(r);
    while (q.next()) boxCandidate(q, r, false, v);
    float t = q.get_committed_intersection_type() == intersection_type::none ? INFINITY : q.get_committed_distance();
    return v.hit ? min(v.distance, t) : t;
}

template <typename I>
inline float intersectorDistance(thread I& isect, Ray r, uint mask, SCENE_ACCEL accel) {
    isect.force_opacity(forced_opacity::opaque);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    return res.type == intersection_type::none ? INFINITY : res.distance;
}

// Closest hit distance only (INFINITY if none).
float intersectDistance(Ray r, uint mask, SCENE_ACCEL accel) {
#if HAS_CURVES
    if (HAIR_CURVES) {
        if (QUERY_LOOP) return queryDistance<intersection_query<curve_data, instancing>>(r, mask, accel);
        intersector<curve_data, instancing> isect;
        isect.assume_geometry_type(queryGeometry(false));
        assumeCurves(isect);
        return intersectorDistance(isect, r, mask, accel);
    }
#endif
    if (QUERY_LOOP) return queryDistance<intersection_query<instancing>>(r, mask, accel);
    intersector<instancing> isect;   // no triangle_data: barycentrics aren't needed
    isect.assume_geometry_type(geometry_type::triangle);
    return intersectorDistance(isect, r, mask, accel);
}

template <typename Q>
inline bool queryAny(Ray r, uint mask, SCENE_ACCEL accel, thread float& t) {
    Q q;
    q.reset(ray(r.origin, r.direction, r.tmin, r.tmax), accel, voxelMask(mask), queryParams(true));
    Hit v = voxelMiss(r);
    while (q.next()) {
        if (boxCandidate(q, r, false, v)) { t = v.distance; return true; }   // any hit will do
    }
    bool hit = q.get_committed_intersection_type() != intersection_type::none;
    t = hit ? q.get_committed_distance() : r.tmax;
    return hit;
}

template <typename I>
inline bool intersectorAny(thread I& isect, Ray r, uint mask, SCENE_ACCEL accel, thread float& t) {
    isect.force_opacity(forced_opacity::opaque);
    isect.accept_any_intersection(true);
    auto res = isect.intersect(ray(r.origin, r.direction, r.tmin, r.tmax), accel, mask);
    t = res.distance;
    return res.type != intersection_type::none;
}

// Any hit (shadow rays): true if something is in the way; `t` = its distance.
bool intersectAny(Ray r, uint mask, SCENE_ACCEL accel, thread float& t) {
#if HAS_CURVES
    if (HAIR_CURVES) {
        if (QUERY_LOOP) return queryAny<intersection_query<curve_data, instancing>>(r, mask, accel, t);
        intersector<curve_data, instancing> isect;
        isect.assume_geometry_type(queryGeometry(false));
        assumeCurves(isect);
        return intersectorAny(isect, r, mask, accel, t);
    }
#endif
    if (QUERY_LOOP) return queryAny<intersection_query<instancing>>(r, mask, accel, t);
    intersector<instancing> isect;
    isect.assume_geometry_type(geometry_type::triangle);
    return intersectorAny(isect, r, mask, accel, t);
}

#else

// Custom BVH traversal (layouts: BVH.swift / CustomRayTracer.swift). Two top-level trees (static instances, built
// once; moving instances, rebuilt every frame) over per-mesh bottom-level trees. Nodes hold both children's boxes;
// a child ref with bit 31 set is a leaf: an instance (top level) or (count - 1) << 28 | first triangle (bottom).
// An instance of an assembly (a generated plant) has a middle level: a tree over the plant's parts, in the plant's
// space, shared by all its instances; its leaves are parts (RTPart), each a placed mesh with its own bottom-level tree.
struct BVHNode {
    float4 lo0;   // xyz = child 0 box min, w = child 0 ref (bits)
    float4 hi0;   // xyz = child 0 box max, w = instance masks under child 0 (bits, top level only)
    float4 lo1;
    float4 hi1;
};

struct RTInstance {
    float4 row0;  // world -> object rows
    float4 row1;
    float4 row2;
    uint blasRoot;
    uint pad0;    // virtual instance + 1 (its BLAS in RTScene.vgBlas), or 0
    uint mask;    // the instance's, and RT_OWN_TREE
    uint pad1;    // FOLIAGE: RT_ASSEMBLY bits = assembly + 1 (blasRoot is then its tree of parts), the top byte = the
                  // voxel level it is traced at this frame + 1, or 0 for its triangles; RT_SWAYS = ground cover
};
constant uint RT_ASSEMBLY = 0x7FFFFFu, RT_SWAYS = 0x800000u;
// STREAMED: a mesh whose tree is in a buffer of its own (MeshBlock.Tree: its nodes, the root first, then its
// triangles, which its leaves count from the buffer's start). In rtPrepKernel's mesh table its root has RT_BLOCK and
// is its place in the table of those trees' addresses; its instances' records have RT_OWN_TREE in their mask and the
// address where blasRoot and pad0 are (RTBlockInstance).
constant uint RT_BLOCK = 0x40000000u, RT_OWN_TREE = 0x80000000u;
// SDF_SHAPES: an SDF shape's instance has RT_SDF in its mask (Scene.instanceSDF) and its shape as its blasRoot: the
// traversal marches the shape where it meets the instance.
constant uint RT_SDF = 0x20000000u;
struct RTBlockInstance {
    float4 row0;
    float4 row1;
    float4 row2;
    device const struct BVHNode* tree;
    uint mask;
    uint pad1;
};
static_assert(sizeof(RTBlockInstance) == 64 && sizeof(RTInstance) == 64, "RTInstance: CustomRayTracer.swift");

struct RTPart {
    float4 row0;  // plant -> part rows
    float4 row1;
    float4 row2;
    uint blasRoot;
    uint mesh;        // the part's mesh, for shading
    uint firstLeaf;   // its triangles from here on take the instance's leaf material (the one after its wood's)
    uint leafCount;   // how many they are, in a shuffled order: autumn drops them from the end (0 = evergreen)
    float4 limb;      // the wind's bones (Shaders/Foliage.metal): xyz = pivot (plant space), w = its largest turn, 0 = none
    float4 limbAxis;  // xyz = the turn's axis, w = phase
    float4 bough;     // the bone on the limb (the part itself, if it hangs on one)
    float4 boughAxis;
};
static_assert(sizeof(RTPart) == 128, "RTPart: CustomRayTracer.swift");

// A part's point (or direction) in the wind: from where it is at rest in its plant's space to where it is now.
inline float3 partWind(RTPart part, PlantWind w, float strength, float3 p, bool point) {
    if (part.bough.w != 0.0f) {
        float a = boneAngle(part.bough, part.boughAxis, w.gust, w.phase, w.time, strength, WIND_BOUGH_SPEED);
        p = point ? windTurn(p, part.bough.xyz, part.boughAxis.xyz, a) : windTurn(p, part.boughAxis.xyz, a);
    }
    if (part.limb.w != 0.0f) {
        float a = boneAngle(part.limb, part.limbAxis, w.gust, w.phase, w.time, strength, WIND_LIMB_SPEED);
        p = point ? windTurn(p, part.limb.xyz, part.limbAxis.xyz, a) : windTurn(p, part.limbAxis.xyz, a);
    }
    return windTurn(p, w.axis, w.angle);   // the root: about the plant's origin
}

struct RTScene {
    device const BVHNode*    tlas;        // static top-level nodes, then this frame's dynamic and cluster trees
    device const BVHNode*    blas;
    device const float4*     tris;        // 3 per triangle: v0 (w = triangle index in its mesh), e1, e2
    device const RTInstance* instances;
    device const uint2*      clusters;    // this frame's selected virtual-geometry clusters: (instance, pool offset)
    device const float4*     pool;        // streamed virtual-geometry pages (VirtualGeometry.swift)
    device const uint*       roots;       // [0] = the cluster tree's root ref, written on the GPU every frame
    device const uint*       nodeInstance; // per cluster-tree node: the scene instance it lies in (see RT_ENTER)
    device atomic_uint*      stats;       // RT_STATS builds: rays, top nodes, bottom nodes, instance entries,
                                          // cluster entries, triangle tests
    device const struct VGBlas* vgBlas;   // per virtual instance: its current cut's BLAS (VirtualBLAS.swift)
    uint staticRoot;                      // root refs; RT_NONE = empty tree
    uint dynamicRoot;
    uint virtualBase;                     // the cluster tree's first node
    uint pad;
    device const RTPart*     parts;       // every assembly's parts (FOLIAGE)
    float4 wind;                          // xy = where the wind blows to (world x, z; unit), z = strength (0 = still),
                                          // w = gustiness; written every frame (CustomRayTracer.encodeBuild)
    float4 windTime;                      // x = this frame's time (s), y = the last frame's, w = the share of the
                                          // leaves that have fallen (the season)
    device const RTVoxels*   voxelGrids;  // per assembly
    device const uint*       voxels;      // their cells
    device const uchar*      cutouts;     // leaf cards' alpha layers, CUTOUT_SIZE squared each (ALPHA_TEST)
    device const SDFScene*   sdf;         // the SDF shapes (SDF_SHAPES)
};
static_assert(sizeof(RTScene) == 176 && __builtin_offsetof(RTScene, cutouts) == 160 && __builtin_offsetof(RTScene, sdf) == 168,
              "RTScene: CustomRayTracer.writeArgs writes these offsets");

#ifndef RT_STATS
#define RT_STATS 0
#endif
#if RT_STATS
#define RT_STAT(i, n) atomic_fetch_add_explicit(&sc.stats[i], (n), memory_order_relaxed)
#else
#define RT_STAT(i, n)
#endif
// Counters (RT_STATS: global; COST traversals: per ray, for the "Traversal cost" view): 0 rays, 1 top nodes,
// 2 bottom nodes, 3 instance entries, 4 cluster and part entries, 5 triangle tests, 6 nodes inside virtual instances
// and assemblies.
// Global only: 7 = pushes the full stack turned away (RT_ROOM).
#define RT_COUNT(i, n) { if (COST) cost[i] += (n); RT_STAT(i, n); }

// A virtual instance's BLAS over its current cut (VirtualBLAS.swift): nodes, triangles (v0 e1 e2, w = index), and per
// triangle 3 octahedral normals + 3 half2 UVs.
struct VGBlas {
    device const BVHNode* nodes;
    device const float4*  tris;
    device const uint*    attrs;
    uint                  triangles;   // 0 = no BLAS yet (the instance is skipped)
    uint                  pad;
};
static_assert(sizeof(VGBlas) == 32, "VGBlas: VirtualBLAS.Entry");

// A virtual-geometry cluster's data in the pool (VirtualGeometryBuilder.clusterBlob): header (2 x uint4), BVH
// nodes, vertices (position + octahedral normal), UVs (half2), triangles (three 8-bit local indices).
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

#define SCENE_ACCEL constant RTScene&

constant uint RT_LEAF  = 0x80000000u;
constant uint RT_NONE  = 0xFFFFFFFFu;
// The traversal's stack: the top level's depth + the bottom level's must fit. A push without room is skipped, and
// with it a subtree: the ray may then miss what it should hit, silently, so RT_STATS counts those (counter 7; none
// in any of the scenes). 48 and 128 entries trace as fast as 64; 32 is 20% slower in the stress hall (measured
// October 2026), so there is nothing to gain from a smaller one.
constant uint RT_STACK = 64;
#if RT_STATS
#define RT_ROOM(sp) ((sp) < RT_STACK || (RT_STAT(7, 1u), false))
#else
#define RT_ROOM(sp) ((sp) < RT_STACK)
#endif

// Slab test of a box against [tmin, tmax]; tnear = entry distance.
inline bool rtSlab(float3 lo, float3 hi, float3 inv, float3 oi, float tmin, float tmax, thread float& tnear) {
    float3 t0 = fma(lo, inv, oi), t1 = fma(hi, inv, oi);
    float3 tn = min(t0, t1), tf = max(t0, t1);
    tnear = max(max(tn.x, tn.y), max(tn.z, tmin));
    return tnear <= min(min(tf.x, tf.y), min(tf.z, tmax));
}

constant uint CUTOUT_SIZE = 512;   // a leaf-card alpha layer's side (FoliageTextures.cardSheetSize)

// A leaf card is there only where its picture is. Its triangles carry their corners' UVs (10 bits a coordinate) and
// their alpha layer + 1 in the spare floats of their edges (BVHBuilder.cutoutBits); two zero words: not a card.
inline bool rtCutout(device const uchar* cutouts, uint a, uint b, float u, float v) {
    uint layer = (a >> 30) | ((b >> 30) << 2);
    if (layer == 0) return true;
    float2 t0 = float2(float(a & 1023u), float((a >> 10) & 1023u));
    float2 t1 = float2(float((a >> 20) & 1023u), float(b & 1023u));
    float2 t2 = float2(float((b >> 10) & 1023u), float((b >> 20) & 1023u));
    float2 uv = (t0 + (t1 - t0) * u + (t2 - t0) * v) * (float(CUTOUT_SIZE) / 1024.0f);
    uint2 texel = min(uint2(uv), uint2(CUTOUT_SIZE - 1u));
    return cutouts[((layer - 1u) * CUTOUT_SIZE + texel.y) * CUTOUT_SIZE + texel.x] != 0;
}

// Möller-Trumbore, both faces. Updates h (closest so far) and returns true on a nearer hit.
// `limit`: triangles of the mesh from this one on aren't there (a plant's fallen leaves). `cutouts`: the alpha
// layers its leaf cards are tested against.
inline bool rtTriangle(float3 o, float3 d, float4 v0, float4 e1, float4 e2, float tmin, thread Hit& h, uint limit = 0xFFFFFFFFu,
                       device const uchar* cutouts = nullptr) {
    float3 pv = cross(d, e2.xyz);
    float det = dot(e1.xyz, pv);
    if (det == 0.0f) return false;
    float inv = 1.0f / det;
    float3 tv = o - v0.xyz;
    float u = dot(tv, pv) * inv;
    if (u < 0.0f || u > 1.0f) return false;
    float3 qv = cross(tv, e1.xyz);
    float v = dot(d, qv) * inv;
    if (v < 0.0f || u + v > 1.0f) return false;
    float t = dot(e2.xyz, qv) * inv;
    if (t < tmin || t > h.distance || as_type<uint>(v0.w) >= limit) return false;
    if (ALPHA_TEST && cutouts != nullptr && !rtCutout(cutouts, as_type<uint>(e1.w), as_type<uint>(e2.w), u, v)) return false;
    h.hit = true;
    h.distance = t;
    h.barycentrics = float2(u, v);
    h.primitive = as_type<uint>(v0.w);
    return true;
}

// The share of its leaves a deciduous plant still has when `fall` of all leaves are down: each plant in its own time.
inline float plantKeep(float fall, uint instance) {
    return 1.0f - saturate(fall * 1.6f - 0.6f * float(pcgHash(instance + 0xFA11u) & 0xFFu) * (1.0f / 255.0f));
}

constant uint RT_INSTANCE_EXIT = 0xFFFFFFFEu;   // stack marker: back to the top level (world space) below here
constant uint RT_CLUSTER = 0x40000000u;         // top-level leaf flag: a virtual-geometry cluster, not an instance
constant uint RT_ENTER   = 0x40000000u;         // internal-node ref flag: the subtree holds one virtual instance's
                                                // clusters, in its object space (enter the instance here)
constant uint RT_OBJECT_EXIT = 0xFFFFFFFDu;     // stack marker: back from a cluster's BVH to its instance's subtree
constant uint RT_PART_EXIT   = 0xFFFFFFFCu;     // stack marker: back from a part's BLAS to its assembly's tree (plant space)

// All levels in one loop: entering an instance switches the ray to object space and pushes a marker; popping the
// marker switches back. Every SIMD lane then runs the same node-fetch code whichever level it is in, instead of
// lanes in a top-level loop waiting for lanes inside a nested bottom-level loop.
// Three top-level trees: static instances, moving instances, and this frame's cut of the virtual meshes. The cut's
// tree splits by instance first: a ref flagged RT_ENTER is one instance's subtree, in its object space, whose leaves
// are clusters with their own small BVHs in the streaming pool. Levels: 0 = world, 1 = inside a virtual instance's
// subtree or an assembly's tree of parts, 2 = inside a BLAS or a cluster's BVH. Returns true on a hit when ANY.
template <bool ANY, bool COST = false>
inline bool rtTraverse(constant RTScene& sc, Ray r, uint mask, thread Hit& h, thread uint* cost = nullptr) {
    uint stack[RT_STACK];
    uint sp = 0;
    uint ref = RT_NONE;
    uint roots[3] = {sc.roots[0], sc.dynamicRoot, sc.staticRoot};   // the last one found is traversed first
    for (uint i = 0; i < 3; ++i) {
        if (roots[i] == RT_NONE) continue;
        if (ref != RT_NONE) stack[sp++] = ref;
        ref = roots[i];
    }
    if (ref == RT_NONE) return false;
    RT_COUNT(0, 1u);

    float3 worldInv = rtSafeInverse(r.direction), worldOi = -r.origin * worldInv;
    float3 o = r.origin, d = r.direction, inv = worldInv, oi = worldOi;
    uint level = 0;
    uint instance = 0;
    device const BVHNode* bottomNodes = sc.blas;
    device const float4* bottomTris = sc.tris;
    uint cluster = HIT_NO_CLUSTER;
    VGClusterView view;
    uint part = HIT_NO_PART;
    float3 plantO = float3(0.0f), plantD = float3(0.0f);   // the ray in the plant's space, while inside an assembly
    bool windy = FOLIAGE && windOn(sc.wind.z > 0.0f);
    float plantGust = 0.0f, plantPhase = 0.0f;             // that plant's wind (PlantWind)
    bool falling = FOLIAGE && sc.windTime.w > 0.0f;        // autumn: the deciduous plants have dropped some leaves
    while (true) {
        if ((ref & RT_LEAF) == 0) {
            if ((ref & RT_ENTER) != 0) {   // a virtual instance's subtree: into its object space (from the world)
                ref &= ~RT_ENTER;
                uint id = sc.nodeInstance[ref - sc.virtualBase];
                RTInstance inst = sc.instances[id];
                if ((inst.mask & mask) != 0 && RT_ROOM(sp)) {
                    float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                    o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                    d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));
                    inv = rtSafeInverse(d);
                    oi = -o * inv;
                    level = 1;
                    instance = id;
                    stack[sp++] = RT_INSTANCE_EXIT;
                    continue;
                }
            } else {
                BVHNode n = level == 2 ? bottomNodes[ref] : sc.tlas[ref];
                bool top = level < 2;
                RT_COUNT(top ? 1 : 2, 1u);
                RT_COUNT(6, level == 1 ? 1u : 0u);   // inside a virtual instance's subtree
                float t0, t1;
                bool b0 = (!top || (as_type<uint>(n.hi0.w) & mask) != 0) && rtSlab(n.lo0.xyz, n.hi0.xyz, inv, oi, r.tmin, h.distance, t0);
                bool b1 = (!top || (as_type<uint>(n.hi1.w) & mask) != 0) && rtSlab(n.lo1.xyz, n.hi1.xyz, inv, oi, r.tmin, h.distance, t1);
                uint c0 = as_type<uint>(n.lo0.w), c1 = as_type<uint>(n.lo1.w);
                if (b0 && b1) {
                    bool swap = t1 < t0;
                    if (RT_ROOM(sp)) stack[sp++] = swap ? c0 : c1;
                    ref = swap ? c1 : c0;
                    continue;
                }
                if (b0 || b1) { ref = b0 ? c0 : c1; continue; }
            }
        } else if (level < 2) {
            uint id = ref & ~RT_LEAF;
            if (FOLIAGE && level == 1 && (id & RT_CLUSTER) == 0) {   // a part of the assembly: into its mesh's BLAS
                if (RT_ROOM(sp)) {
                    device const RTPart& p = sc.parts[id];   // a reference: the bones are read only in the wind
                    float3 po = plantO, pd = plantD;
                    if (windy) {   // the ray, turned back to where the part is at rest: its limb's turn, then its own
                        if (p.limb.w != 0.0f) {
                            float a = -boneAngle(p.limb, p.limbAxis, plantGust, plantPhase, sc.windTime.x, sc.wind.z, WIND_LIMB_SPEED);
                            po = windTurn(po, p.limb.xyz, p.limbAxis.xyz, a);
                            pd = windTurn(pd, p.limbAxis.xyz, a);
                        }
                        if (p.bough.w != 0.0f) {
                            float a = -boneAngle(p.bough, p.boughAxis, plantGust, plantPhase, sc.windTime.x, sc.wind.z, WIND_BOUGH_SPEED);
                            po = windTurn(po, p.bough.xyz, p.boughAxis.xyz, a);
                            pd = windTurn(pd, p.boughAxis.xyz, a);
                        }
                    }
                    float4 o4 = float4(po, 1.0f), d4 = float4(pd, 0.0f);
                    o = float3(dot(p.row0, o4), dot(p.row1, o4), dot(p.row2, o4));
                    d = float3(dot(p.row0, d4), dot(p.row1, d4), dot(p.row2, d4));
                    inv = rtSafeInverse(d);
                    oi = -o * inv;
                    level = 2;
                    part = id;
                    cluster = HIT_NO_CLUSTER;
                    bottomNodes = sc.blas;
                    bottomTris = sc.tris;
                    RT_COUNT(4, 1u);
                    stack[sp++] = RT_PART_EXIT;
                    ref = p.blasRoot;
                    continue;
                }
            } else if ((id & RT_CLUSTER) != 0) {   // a cluster: into its BVH (already in object space inside a subtree)
                cluster = id & ~RT_CLUSTER;
                uint2 rc = sc.clusters[cluster];
                bool enter = level == 0;    // a lone cluster in the world-space part of the tree
                RTInstance inst;
                if (enter) inst = sc.instances[rc.x];
                if ((!enter || (inst.mask & mask) != 0) && RT_ROOM(sp)) {
                    if (enter) {
                        float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                        o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                        d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));
                        inv = rtSafeInverse(d);
                        oi = -o * inv;
                        instance = rc.x;
                    }
                    view = vgClusterView(sc.pool + rc.y);
                    bottomNodes = view.nodes;
                    RT_COUNT(4, 1u);
                    stack[sp++] = enter ? RT_INSTANCE_EXIT : RT_OBJECT_EXIT;
                    level = 2;
                    ref = 0;
                    continue;
                }
            } else {                         // an ordinary instance (or a virtual mesh's cut): into its BLAS
                RTInstance inst = sc.instances[id];
                device const BVHNode* nodes = sc.blas;
                device const float4* tris = sc.tris;
                uint root = inst.blasRoot;
                bool present = true;
                if (STREAMED && (inst.mask & RT_OWN_TREE) != 0) {   // its tree is in a buffer of its own
                    nodes = ((device const RTBlockInstance*)sc.instances)[id].tree;
                    tris = (device const float4*)nodes;
                    root = 0;
                } else if (inst.pad0 != 0) {
                    VGBlas e = sc.vgBlas[inst.pad0 - 1];
                    nodes = e.nodes; tris = e.tris; root = 0;
                    present = e.triangles != 0;
                }
                if (SDF_SHAPES && (inst.mask & RT_SDF) != 0) {   // an SDF shape: marched here, in the instance's space
                    present = false;
                    if ((inst.mask & mask) != 0) {
                        float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                        float3 so = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                        float3 sd = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));
                        float t;
                        float2 n = float2(0.0f);
                        uint material, steps = 0;
                        RT_COUNT(3, 1u);
                        bool met = sdfMarch(*sc.sdf, inst.blasRoot, so, sd, r.tmin, h.distance, length(r.direction), !ANY, t, n, material, steps);
                        RT_COUNT(5, steps);
                        if (met) {
                            h.hit = true;
                            h.distance = t;
                            h.barycentrics = n;
                            h.primitive = material;
                            h.instance = id;
                            h.cluster = HIT_NO_CLUSTER;
                            h.part = HIT_SDF;
                            if (ANY) return true;
                        }
                    }
                }
                if (present && (inst.mask & mask) != 0 && RT_ROOM(sp)) {
                    float4 o4 = float4(r.origin, 1.0f), d4 = float4(r.direction, 0.0f);
                    o = float3(dot(inst.row0, o4), dot(inst.row1, o4), dot(inst.row2, o4));
                    d = float3(dot(inst.row0, d4), dot(inst.row1, d4), dot(inst.row2, d4));   // not normalized: t is shared
                    inv = rtSafeInverse(d);
                    oi = -o * inv;
                    instance = id;
                    RT_COUNT(3, 1u);
                    uint assembly = inst.pad1 & RT_ASSEMBLY, voxelLevel = inst.pad1 >> 24;
                    if (FOLIAGE && assembly != 0) {   // an assembly: the tree over its parts, in the plant's space
                        if (windy) {   // ... as it stands before the wind leans it: the root's turn, undone
                            PlantWind plant = plantWind(sc.wind, sc.windTime.x, inst.row0, inst.row1, inst.row2, id);
                            plantGust = plant.gust;
                            plantPhase = plant.phase;
                            o = windTurn(o, plant.axis, -plant.angle);
                            d = windTurn(d, plant.axis, -plant.angle);
                            inv = rtSafeInverse(d);
                            oi = -o * inv;
                        }
                        // Far from the camera, its voxels instead, at the level rtPrepKernel chose for it this frame.
                        if (voxelLevel != 0) {
                            uint seed = voxelSeed(r, id);
                            if (rtVoxels(sc.voxels, sc.voxelGrids[assembly - 1u], voxelLevel - 1u, o, d, inv, oi, r.tmin, seed, falling ? plantKeep(sc.windTime.w, id) : 1.0f, h)) {
                                h.instance = id;
                                if (ANY) return true;
                            }
                            o = r.origin; d = r.direction; inv = worldInv; oi = worldOi;   // and on, in the world
                        } else {
                            level = 1;
                            plantO = o;
                            plantD = d;
                            stack[sp++] = RT_INSTANCE_EXIT;
                            ref = root;
                            continue;
                        }
                    } else {
                        if (windy && (inst.pad1 & RT_SWAYS) != 0) {   // ground cover: the ray, sheared back to where it stands at rest
                            float3 lean = coverLean(sc.wind, sc.windTime.x, inst.row0, inst.row1, inst.row2);
                            o -= lean * o.y;
                            d -= lean * d.y;
                            inv = rtSafeInverse(d);
                            oi = -o * inv;
                        }
                        stack[sp++] = RT_INSTANCE_EXIT;
                        ref = root;
                        level = 2;
                        cluster = HIT_NO_CLUSTER;
                        part = HIT_NO_PART;
                        bottomNodes = nodes;
                        bottomTris = tris;
                        continue;
                    }
                }
            }
        } else if (ref != RT_NONE) {   // RT_NONE: the empty child of a single-leaf mesh
            uint first = ref & 0x0FFFFFFFu, end = first + ((ref >> 28) & 7u) + 1u;
            RT_COUNT(5, end - first);
            if (cluster != HIT_NO_CLUSTER) {
                for (uint t = first; t < end; ++t) {
                    uint packed = view.tris[t];
                    float3 p0 = view.positions[packed & 0xFFu].xyz, p1 = view.positions[(packed >> 8) & 0xFFu].xyz;
                    float3 p2 = view.positions[(packed >> 16) & 0xFFu].xyz;
                    if (rtTriangle(o, d, float4(p0, as_type<float>(t)), float4(p1 - p0, 0.0f), float4(p2 - p0, 0.0f), r.tmin, h)) {
                        h.instance = instance;
                        h.cluster = cluster;
                        h.part = HIT_NO_PART;
                        if (ANY) return true;
                    }
                }
            } else {
                // The part's triangles from `limit` on have fallen (worked out here, from what the loop holds anyway:
                // a value kept across the loop for it cost the traversal 0.7 ms a frame in the wind).
                uint limit = 0xFFFFFFFFu;
                if (falling && part != HIT_NO_PART) {
                    device const RTPart& p = sc.parts[part];
                    if (p.leafCount != 0) limit = p.firstLeaf + uint(float(p.leafCount) * plantKeep(sc.windTime.w, instance));
                }
                for (uint t = first; t < end; ++t) {
                    if (rtTriangle(o, d, bottomTris[3 * t], bottomTris[3 * t + 1], bottomTris[3 * t + 2], r.tmin, h, limit, STREAMED || bottomTris == sc.tris ? sc.cutouts : nullptr)) {   // a virtual BLAS keeps other things there (a streamed scene has none)
                        h.instance = instance;
                        h.cluster = HIT_NO_CLUSTER;
                        h.part = part;
                        if (ANY) return true;
                    }
                }
            }
        }
        while (true) {
            if (sp == 0) return false;
            ref = stack[--sp];
            if (ref == RT_INSTANCE_EXIT) {
                level = 0;
                o = r.origin; d = r.direction; inv = worldInv; oi = worldOi;
                continue;
            }
            if (ref == RT_OBJECT_EXIT) {
                level = 1;
                continue;
            }
            if (FOLIAGE && ref == RT_PART_EXIT) {
                level = 1;
                o = plantO; d = plantD;
                inv = rtSafeInverse(d);
                oi = -o * inv;
                continue;
            }
            break;
        }
    }
}

Hit intersectClosest(Ray r, uint mask, SCENE_ACCEL sc) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.barycentrics = float2(0.0f);
    h.instance = 0;
    h.primitive = 0;
    h.cluster = HIT_NO_CLUSTER;
    h.part = HIT_NO_PART;
    rtTraverse<false>(sc, r, mask, h);
    return h;
}

// Closest hit, counting the traversal's work into cost[0..6] (see RT_COUNT): the "Traversal cost" view only.
Hit intersectClosestCost(Ray r, uint mask, SCENE_ACCEL sc, thread uint* cost) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.barycentrics = float2(0.0f);
    h.instance = 0;
    h.primitive = 0;
    h.cluster = HIT_NO_CLUSTER;
    h.part = HIT_NO_PART;
    rtTraverse<false, true>(sc, r, mask, h, cost);
    return h;
}

float intersectDistance(Ray r, uint mask, SCENE_ACCEL sc) {
    Hit h = intersectClosest(r, mask, sc);
    return h.hit ? h.distance : INFINITY;
}

bool intersectAny(Ray r, uint mask, SCENE_ACCEL sc, thread float& t) {
    Hit h;
    h.hit = false;
    h.distance = r.tmax;
    h.cluster = HIT_NO_CLUSTER;
    h.part = HIT_NO_PART;
    bool hit = rtTraverse<true>(sc, r, mask, h);
    t = h.distance;
    return hit;
}

#endif
