// ---------------------------------------------------------------------------------------------
// Liquids' surfaces (FluidSurface.swift): splat, blur, surface nets into the scene's vertex and index buffers
// ---------------------------------------------------------------------------------------------

// FluidSystem.cpuSurface is the reference: the same integers splatted, the same blur, the vertices and quads in the
// cells' order (scans of the cells' counts put them there).

struct FluidSurface {
    float4 lo;          // w = cell
    uint4  dims;        // nodes; w = all
    float4 field;       // iso, the splat's fixed point, 1 / cell
    uint4  mesh;        // first vertex (indices are the vertex buffer's), first index, last frame's offset, vertices it holds
    uint4  triangles;   // x = triangles it holds
};
static_assert(sizeof(FluidSurface) == 80, "FluidSurface: GPUFluidSurface");

inline uint fluidSurfaceNode(int3 c, constant FluidSurface& s) { return uint(c.x) + s.dims.x * (uint(c.y) + s.dims.y * uint(c.z)); }
inline int3 fluidSurfaceCoords(uint k, constant FluidSurface& s) {
    return int3(k % s.dims.x, (k / s.dims.x) % s.dims.y, k / (s.dims.x * s.dims.y));
}

kernel void fluidSurfaceClearKernel(constant FluidSurface& s [[buffer(0)]], device int* density [[buffer(2)]], uint k [[thread_position_in_grid]]) {
    if (k < s.dims.w) density[k] = 0;
}

// Each particle's weight onto the 8 nodes about it, in fixed point.
kernel void fluidSurfaceSplatKernel(constant FluidSurface&      s         [[buffer(0)]],
                                    device const FluidState&    st        [[buffer(1)]],
                                    device atomic_int*          density   [[buffer(2)]],
                                    device const FluidParticle* particles [[buffer(4)]],
                                    uint i [[thread_position_in_grid]])
{
    if (i >= st.counts.y) return;
    float3 g = (particles[i].position.xyz - s.lo.xyz) * s.field.z;
    int3 base = clamp(int3(floor(g)), int3(0), int3(s.dims.xyz) - 2);
    float3 f = clamp(g - float3(base), 0.0f, 1.0f);
    for (int k = 0; k < 8; ++k) {
        int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
        float w = (o.x == 0 ? 1.0f - f.x : f.x) * (o.y == 0 ? 1.0f - f.y : f.y) * (o.z == 0 ? 1.0f - f.z : f.z);
        atomic_fetch_add_explicit(&density[fluidSurfaceNode(base + o, s)], fluidFixed(w, s.field.y), memory_order_relaxed);
    }
}

// One pass of the [1 4 6 4 1] / 16 blur along pass.x (the first from the splat's integers, pass.y = 1); the last
// (along z) holds the border at 0.
kernel void fluidSurfaceBlurKernel(constant FluidSurface& s       [[buffer(0)]],
                                   device const int*      density [[buffer(2)]],
                                   device const float*    in      [[buffer(3)]],
                                   device float*          out     [[buffer(5)]],
                                   constant uint4&        pass    [[buffer(6)]],
                                   uint k [[thread_position_in_grid]])
{
    if (k >= s.dims.w) return;
    int3 c = fluidSurfaceCoords(k, s), n = int3(s.dims.xyz);
    const float taps[5] = {1.0f, 4.0f, 6.0f, 4.0f, 1.0f};
    float sum = 0.0f;
    for (int t = -2; t <= 2; ++t) {
        int3 q = c;
        q[pass.x] += t;
        if (any(q < 0) || any(q >= n)) continue;
        uint m = fluidSurfaceNode(q, s);
        sum += taps[t + 2] * (pass.y == 1 ? float(density[m]) / s.field.y : in[m]);
    }
    bool border = any(c == 0) || any(c == n - 1);
    out[k] = pass.x == 2 && border ? 0.0f : sum / 16.0f;
}

// FluidSystem.corner, edges.
constant uchar2 FLUID_EDGES[12] = {uchar2(0, 1), uchar2(2, 3), uchar2(4, 5), uchar2(6, 7), uchar2(0, 2), uchar2(1, 3),
                                   uchar2(4, 6), uchar2(5, 7), uchar2(0, 4), uchar2(1, 5), uchar2(2, 6), uchar2(3, 7)};
inline float3 fluidCorner(uint k) { return float3(k & 1, (k >> 1) & 1, k >> 2); }

// The cell from node c's eight values; whether the surface crosses it.
inline bool fluidSurfaceCell(int3 c, constant FluidSurface& s, device const float* field, thread float* v) {
    if (any(c + 1 >= int3(s.dims.xyz))) return false;
    uint inside = 0;
    for (uint k = 0; k < 8; ++k) {
        v[k] = field[fluidSurfaceNode(c + int3(k & 1, (k >> 1) & 1, k >> 2), s)];
        if (v[k] > s.field.x) inside++;
    }
    return inside > 0 && inside < 8;
}

// FluidSystem.surfaceQuads: the edges from node c along +x, +y, +z the surface crosses (bit a), whose four cells are
// in the grid; bit 3 + a: the edge's first node is inside.
inline uint fluidSurfaceEdges(int3 c, constant FluidSurface& s, device const float* field) {
    uint bits = 0;
    int3 n = int3(s.dims.xyz);
    bool in0 = field[fluidSurfaceNode(c, s)] > s.field.x;
    for (int a = 0; a < 3; ++a) {
        int b = (a + 1) % 3, d = (a + 2) % 3;
        int3 q = c;
        q[a] += 1;
        if (q[a] >= n[a] || c[b] < 1 || c[d] < 1) continue;
        if (in0 == (field[fluidSurfaceNode(q, s)] > s.field.x)) continue;
        bits |= 1u << a;
        if (in0) bits |= 8u << a;
    }
    return bits;
}

// Per node: whether its cell has a vertex, and how many quads its edges make.
kernel void fluidSurfaceCountKernel(constant FluidSurface& s      [[buffer(0)]],
                                    device const float*    field  [[buffer(3)]],
                                    device uint*           verts  [[buffer(7)]],
                                    device uint*           quads  [[buffer(8)]],
                                    uint k [[thread_position_in_grid]])
{
    if (k >= s.dims.w) return;
    int3 c = fluidSurfaceCoords(k, s);
    float v[8];
    verts[k] = fluidSurfaceCell(c, s, field, v) ? 1u : 0u;
    quads[k] = popcount(fluidSurfaceEdges(c, s, field) & 7u);
}

// FluidSystem.surfaceVertex, into the scene's vertex buffers at the place the scan gave it (last frame's copy: the
// same, a liquid's surface has no motion of its own to blur).
kernel void fluidSurfaceVertexKernel(constant FluidSurface& s         [[buffer(0)]],
                                     device const float*    field     [[buffer(3)]],
                                     device const uint*     vertexAt  [[buffer(9)]],
                                     device float3*         positions [[buffer(10)]],
                                     device float3*         normals   [[buffer(11)]],
                                     uint k [[thread_position_in_grid]])
{
    if (k >= s.dims.w || vertexAt[k + 1] == vertexAt[k]) return;
    uint at = vertexAt[k];
    if (at >= s.mesh.w) return;
    int3 c = fluidSurfaceCoords(k, s);
    float v[8];
    fluidSurfaceCell(c, s, field, v);
    float3 sum = float3(0.0f);
    float count = 0.0f;
    for (uint e = 0; e < 12; ++e) {
        float fa = v[FLUID_EDGES[e].x], fb = v[FLUID_EDGES[e].y];
        if ((fa > s.field.x) == (fb > s.field.x)) continue;
        float t = (s.field.x - fa) / (fb - fa);
        float3 pa = fluidCorner(FLUID_EDGES[e].x), pb = fluidCorner(FLUID_EDGES[e].y);
        sum += pa + (pb - pa) * t;
        count += 1.0f;
    }
    float3 f = sum / count;
    float gx = mix(mix(v[1] - v[0], v[3] - v[2], f.y), mix(v[5] - v[4], v[7] - v[6], f.y), f.z);
    float gy = mix(mix(v[2] - v[0], v[3] - v[1], f.x), mix(v[6] - v[4], v[7] - v[5], f.x), f.z);
    float gz = mix(mix(v[4] - v[0], v[5] - v[1], f.x), mix(v[6] - v[2], v[7] - v[3], f.x), f.y);
    float3 g = float3(gx, gy, gz);
    float l = length(g);
    float3 p = s.lo.xyz + (float3(c) + f) * s.lo.w;
    uint i = s.mesh.x + at;
    positions[i] = p;
    positions[i + s.mesh.z] = p;
    normals[i] = l > 1e-12f ? -g / l : float3(0, 1, 0);
}

// FluidSystem.surfaceQuads: each crossing edge's two triangles at the place the scan gave its quad, wound outward.
kernel void fluidSurfaceQuadKernel(constant FluidSurface& s        [[buffer(0)]],
                                   device const float*    field    [[buffer(3)]],
                                   device const uint*     vertexAt [[buffer(9)]],
                                   device const uint*     quadAt   [[buffer(12)]],
                                   device uint*           indices  [[buffer(13)]],
                                   uint k [[thread_position_in_grid]])
{
    if (k >= s.dims.w || quadAt[k + 1] == quadAt[k]) return;
    int3 c = fluidSurfaceCoords(k, s);
    uint bits = fluidSurfaceEdges(c, s, field), q = quadAt[k];
    for (int a = 0; a < 3; ++a) {
        if ((bits & (1u << a)) == 0) continue;
        int b = (a + 1) % 3, d = (a + 2) % 3;
        const int2 around[4] = {int2(-1, -1), int2(0, -1), int2(0, 0), int2(-1, 0)};
        uint v[4];
        bool fits = true;
        for (int j = 0; j < 4; ++j) {
            int3 cell = c;
            cell[b] += around[j].x;
            cell[d] += around[j].y;
            v[j] = vertexAt[fluidSurfaceNode(cell, s)];
            fits = fits && v[j] < s.mesh.w;
        }
        if ((bits & (8u << a)) == 0) { uint t = v[1]; v[1] = v[3]; v[3] = t; }
        if (2 * q + 1 < s.triangles.x) {
            device uint* out = indices + s.mesh.y + 6 * q;
            uint base = s.mesh.x, spare = s.mesh.w;
            for (int j = 0; j < 4; ++j) v[j] = base + (fits ? v[j] : spare);
            out[0] = v[0]; out[1] = v[1]; out[2] = v[2];
            out[3] = v[0]; out[4] = v[2]; out[5] = v[3];
        }
        q++;
    }
}

// The triangles past what the surface needs: degenerate, at the spare vertex (where the box's middle is); and the
// counts (vertices, triangles, whether it ran out) for the CPU.
kernel void fluidSurfaceTailKernel(constant FluidSurface& s         [[buffer(0)]],
                                   device const uint*     vertexAt  [[buffer(9)]],
                                   device float3*         positions [[buffer(10)]],
                                   device const uint*     quadAt    [[buffer(12)]],
                                   device uint*           indices   [[buffer(13)]],
                                   device uint4*          stats     [[buffer(14)]],
                                   uint t [[thread_position_in_grid]])
{
    uint used = min(2 * quadAt[s.dims.w], s.triangles.x);
    if (t == 0) {
        float3 middle = s.lo.xyz + float3(s.dims.xyz - 1) * (0.5f * s.lo.w);
        positions[s.mesh.x + s.mesh.w] = middle;
        positions[s.mesh.x + s.mesh.w + s.mesh.z] = middle;
        uint v = vertexAt[s.dims.w];
        *stats = uint4(v, 2 * quadAt[s.dims.w], v > s.mesh.w || 2 * quadAt[s.dims.w] > s.triangles.x ? 1u : 0u, 0u);
    }
    if (t < used || t >= s.triangles.x) return;
    device uint* out = indices + s.mesh.y + 3 * t;
    out[0] = out[1] = out[2] = s.mesh.x + s.mesh.w;
}
