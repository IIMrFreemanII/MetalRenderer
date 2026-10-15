// ---------------------------------------------------------------------------------------------
// The light tree (LightTree.swift): the path tracer's many lights (more than PT_LIGHT_HITS). A bounding hierarchy over
// every light but the suns. A light is drawn by walking
// down from the root, at each node in proportion to its children's weights at the pixel; its probability is the
// product of those choices, which lightTreePdf computes back along the light's path.
// ---------------------------------------------------------------------------------------------

struct LightTreeNode {
    float4 lo;     // xyz = bounds min, w = power (intensity luminance)
    float4 hi;     // xyz = bounds max, w = cos θo, the cone's spread (-1: every direction)
    float4 axis;   // xyz = the cone's axis, w = cos θe: how far past θo the lights still emit
    uint4  link;   // x = left child or LIGHT_TREE_LEAF | light index, y = right child, z = parent
};
constant uint LIGHT_TREE_LEAF = 1u << 31;

// cos(max(0, a - b)) from the sines and cosines of a and b.
inline float cosSubClamped(float sinA, float cosA, float sinB, float cosB) { return cosA > cosB ? 1.0f : cosA * cosB + sinA * sinB; }
inline float sinSubClamped(float sinA, float cosA, float sinB, float cosB) { return cosA > cosB ? 0.0f : sinA * cosB - cosA * sinB; }

// A node's importance at p with normal n (Conty Estevez & Kulla 2018, PBRT-v4's LightBounds::Importance, one-sided):
// a bound on its lights' unshadowed light, in lightUnshadowed's units: power / (pi d^2) x the cosine at the lights'
// cone and at the receiver, both widened by the box's angular size. `volume`: p is in a medium (the reference path
// tracer's fog), which has no receiver cosine.
inline float lightTreeImportance(LightTreeNode node, float3 p, float3 n, bool volume = false) {
    float power = node.lo.w;
    if (power <= 0.0f) return 0.0f;
    float3 lo = node.lo.xyz, hi = node.hi.xyz, pc = 0.5f * (lo + hi);
    float r2 = 0.25f * distance_squared(lo, hi);
    float3 w = p - pc;
    float d2 = dot(w, w);
    float sinB = 0.0f, cosB = -1.0f;   // the box's angular radius from p (inside it: every direction)
    if (d2 > r2 && !(all(p >= lo) && all(p <= hi))) { sinB = sqrt(r2 / d2); cosB = sqrt(max(1.0f - r2 / d2, 0.0f)); }
    float3 wn = w * rsqrt(max(d2, 1e-12f));
    float cosO = node.hi.w, sinO = sqrt(max(1.0f - cosO * cosO, 0.0f));
    float cosW = dot(node.axis.xyz, wn), sinW = sqrt(max(1.0f - cosW * cosW, 0.0f));
    float cosX = cosSubClamped(sinW, cosW, sinO, cosO), sinX = sinSubClamped(sinW, cosW, sinO, cosO);
    float cosP = cosSubClamped(sinX, cosX, sinB, cosB);
    if (cosP <= node.axis.w) return 0.0f;
    float cosIp = 1.0f;
    if (!volume) {
        float cosI = -dot(n, wn), sinI = sqrt(max(1.0f - cosI * cosI, 0.0f));
        cosIp = cosSubClamped(sinI, cosI, sinB, cosB);
        if (cosIp <= 0.0f) return 0.0f;
    }
    return power * cosP * cosIp / (M_PI_F * max(d2, r2));
}

// A child's weight: a leaf's light's exact unshadowed diffuse light (the mesh lights' proxy), else its bound. `volume`: at a point in a medium (lightVolumeWeight, no receiver cosine).
inline float lightTreeWeight(device const LightTreeNode* tree, uint i, thread const ShadingPoint& sp, device const Light* lights,
                             bool volume = false) {
    LightTreeNode node = tree[i];
    if ((node.link.x & LIGHT_TREE_LEAF) != 0) {
        uint l = node.link.x & ~LIGHT_TREE_LEAF;
        return volume ? lightVolumeWeight(lights[l], sp.p) : luminance(lightUnshadowed(lights[l], sp.p, sp.n, sp.ng));
    }
    return lightTreeImportance(node, sp.p, sp.n, volume);
}

// A light drawn from the tree with one random number (rescaled at every choice), and its probability (0: none).
inline uint sampleLightTree(device const LightTreeNode* tree, uint nodes, float u, thread const ShadingPoint& sp,
                            device const Light* lights, thread float& pdf, bool volume = false) {
    pdf = 0.0f;
    if (nodes == 0) return ELEMENT_NONE;
    uint i = 0;
    float p = 1.0f;
    for (uint depth = 0; depth < 33; ++depth) {
        uint2 link = tree[i].link.xy;
        if ((link.x & LIGHT_TREE_LEAF) != 0) {
            uint l = link.x & ~LIGHT_TREE_LEAF;
            pdf = p;
            return l;
        }
        float wl = lightTreeWeight(tree, link.x, sp, lights, volume), wr = lightTreeWeight(tree, link.y, sp, lights, volume);
        if (!(wl + wr > 0.0f)) return ELEMENT_NONE;
        float pl = wl / (wl + wr);
        if (u < pl) { u = min(u / pl, 0.99999f); p *= pl; i = link.x; }
        else { u = min((u - pl) / (1.0f - pl), 0.99999f); p *= 1.0f - pl; i = link.y; }
    }
    return ELEMENT_NONE;
}

// The probability that sampleLightTree draws light l at the pixel.
inline float lightTreePdf(device const LightTreeNode* tree, uint nodes, uint l, thread const ShadingPoint& sp,
                          device const Light* lights, bool volume = false) {
    if (nodes == 0) return 0.0f;
    uint2 path = ((device const uint2*)(tree + nodes))[l];
    if (path.y > 32) return 0.0f;   // not in the tree (the suns)
    uint i = 0;
    float p = 1.0f;
    for (uint depth = 0; depth < path.y; ++depth) {
        uint2 link = tree[i].link.xy;
        float wl = lightTreeWeight(tree, link.x, sp, lights, volume), wr = lightTreeWeight(tree, link.y, sp, lights, volume);
        if (!(wl + wr > 0.0f)) return 0.0f;
        bool right = ((path.x >> depth) & 1u) != 0;
        p *= (right ? wr : wl) / (wl + wr);
        i = right ? link.y : link.x;
    }
    return p;
}
