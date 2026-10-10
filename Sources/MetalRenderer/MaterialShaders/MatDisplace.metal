// Displacement (Scene+Displacement.swift, Renderer.encodeDisplacement): a displaced mesh's vertices moved from where
// they were along their group's normal by the material's height, the group's members' heights averaged (the vertices
// at one point read their own UVs: a seam's two sides then move alike and the surface stays closed).

#if !MAT_EVAL_ONLY
// A displaced mesh's dispatch (Swift: MatDisplaceArgs, the same layout).
struct MatDisplaceArgs {
    uint first;       // its vertices in the scene's positions and UVs
    uint count;
    uint records;     // its first vertex's records in `vertices` (two a vertex)
    uint members;     // its groups' first member in `members`
    float amount;     // the mesh's units from black to white
    float mid;        // the height that stays
    float uvScale;    // the material's
    float lod;        // the height's level at the vertices' spacing
};

constexpr sampler matDisplaceSampler(filter::linear, mip_filter::linear, address::repeat, coord::normalized);

kernel void matDisplace(constant MatDisplaceArgs& a        [[buffer(0)]],
                        device const float4*      vertices [[buffer(1)]],
                        device const uint*        members  [[buffer(2)]],
                        device const float2*      uvs      [[buffer(3)]],
                        device float3*            positions [[buffer(4)]],
                        texture2d<float>          height   [[texture(0)]],
                        uint                      i        [[thread_position_in_grid]])
{
    if (i >= a.count) return;
    float4 at = vertices[2 * (a.records + i)], way = vertices[2 * (a.records + i) + 1];
    uint start = as_type<uint>(at.w), n = max(as_type<uint>(way.w), 1u);
    float h = 0.0f;
    for (uint k = 0; k < n; ++k) {
        uint v = members[a.members + start + k];
        h += height.sample(matDisplaceSampler, uvs[a.first + v] * a.uvScale, level(a.lod)).r;
    }
    positions[a.first + i] = at.xyz + way.xyz * ((h / float(n) - a.mid) * a.amount);
}
#endif
