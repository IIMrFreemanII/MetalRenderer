// ---------------------------------------------------------------------------------------------
// Crowd: skinned characters animated on the GPU (Crowd.swift, CrowdSkinner.swift).
// A pose slot is one character in one pose; many instances share it. Every frame:
//   crowdPoseKernel   each slot's skinning matrices, from its clips' keys (one thread per joint and slot);
//   crowdSkinKernel   each slot's vertices, from the bind-pose mesh (one thread per vertex and slot), into the slot's
//                     range of the scene's position and normal buffers, after keeping the old positions for motion.
// Metal then refits each slot's acceleration structure around its new triangles (SceneBuffers.primitiveRefit).
// SkinnedCharacter.palette / skin are the same math on the CPU (the reference CrowdSkinner.check compares with).
// ---------------------------------------------------------------------------------------------

struct SkinVertex {
    uint joints;      // four joint indices, a byte each (the first in the low byte)
    float w0;         // the first three joints' weights; the fourth's is what is left of 1
    float w1;
    float w2;
};
static_assert(sizeof(SkinVertex) == 16, "SkinVertex: GPUSkinVertex");

struct CrowdJoint {
    float4 local;                    // xyz = translation in the parent's space, w = the parent's index + 1 (bits; 0 = root)
    float4 inverseBindRotation;      // quaternion (xyzw)
    float4 inverseBindTranslation;   // xyz
};
static_assert(sizeof(CrowdJoint) == 48, "CrowdJoint: GPUJoint");

struct PoseSlot {
    uint rotationsA;  // clip A's first rotation key (a quaternion per joint and key) ...
    uint rootA;       // ... and its first root-translation key
    uint rotationsB;
    uint rootB;
    float timeA;      // in keys, inside the loop
    float timeB;
    float blend;      // 0 = clip A alone
    float pad;
};
static_assert(sizeof(PoseSlot) == 32, "PoseSlot: GPUPoseSlot");

struct JointMatrix {
    float4 row0;      // the rows of bind space -> posed space
    float4 row1;
    float4 row2;
};
static_assert(sizeof(JointMatrix) == 48, "JointMatrix: GPUJointMatrix");

// One character's slots (CrowdSkinner.PoseParams).
struct CrowdPoseParams {
    uint jointBase;       // the character's first joint
    uint jointCount;
    uint firstSlot;
    uint slotCount;
    uint paletteStride;   // matrices per slot in the palette
    uint pad0, pad1, pad2;
};
static_assert(sizeof(CrowdPoseParams) == 32, "CrowdPoseParams: CrowdSkinner.PoseParams");

// One part's slots (CrowdSkinner.SkinParams): slot s's vertices are at currentBase + s * vertexCount.
struct CrowdSkinParams {
    uint bindBase;        // the bind-pose mesh's first vertex
    uint vertexCount;
    uint currentBase;
    uint previousBase;
    uint skinBase;        // the part's first SkinVertex
    uint firstSlot;
    uint slotCount;
    uint paletteStride;
};
static_assert(sizeof(CrowdSkinParams) == 32, "CrowdSkinParams: CrowdSkinner.SkinParams");

inline float4 quatMul(float4 a, float4 b) {
    return float4(a.w * b.xyz + b.w * a.xyz + cross(a.xyz, b.xyz), a.w * b.w - dot(a.xyz, b.xyz));
}
inline float3 quatRotate(float4 q, float3 v) {
    float3 t = 2.0f * cross(q.xyz, v);
    return v + q.w * t + cross(q.xyz, t);
}
// Normalized blend, the short way round.
inline float4 quatNlerp(float4 a, float4 b, float t) {
    b = dot(a, b) < 0.0f ? -b : b;
    return normalize(a + (b - a) * t);
}

// A joint's rotation in its parent's space in a slot's pose: between two keys of clip A, then toward clip B's.
inline float4 crowdRotation(device const float4* keys, PoseSlot s, uint joint, uint jointCount) {
    uint a = uint(s.timeA);
    float4 q = quatNlerp(keys[s.rotationsA + a * jointCount + joint], keys[s.rotationsA + (a + 1) * jointCount + joint],
                         s.timeA - float(a));
    if (s.blend > 0.0f) {
        uint b = uint(s.timeB);
        float4 qb = quatNlerp(keys[s.rotationsB + b * jointCount + joint], keys[s.rotationsB + (b + 1) * jointCount + joint],
                              s.timeB - float(b));
        q = quatNlerp(q, qb, s.blend);
    }
    return q;
}

// The root joint's translation in a slot's pose.
inline float3 crowdRoot(device const float4* roots, PoseSlot s) {
    uint a = uint(s.timeA);
    float3 t = mix(roots[s.rootA + a].xyz, roots[s.rootA + a + 1].xyz, s.timeA - float(a));
    if (s.blend > 0.0f) {
        uint b = uint(s.timeB);
        t = mix(t, mix(roots[s.rootB + b].xyz, roots[s.rootB + b + 1].xyz, s.timeB - float(b)), s.blend);
    }
    return t;
}

// A joint's skinning matrix in a slot's pose. The thread walks up from its joint to the root, composing the
// rotations and offsets on the way (a skeleton is about a dozen joints deep), so no pass per level is needed.
kernel void crowdPoseKernel(constant CrowdPoseParams& p         [[buffer(0)]],
                            device const CrowdJoint*  joints    [[buffer(1)]],
                            device const float4*      rotations [[buffer(2)]],
                            device const float4*      roots     [[buffer(3)]],
                            device const PoseSlot*    slots     [[buffer(4)]],
                            device JointMatrix*       palette   [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.jointCount || gid.y >= p.slotCount) return;
    PoseSlot slot = slots[p.firstSlot + gid.y];
    CrowdJoint joint = joints[p.jointBase + gid.x];
    uint parent = as_type<uint>(joint.local.w);
    float4 q = crowdRotation(rotations, slot, gid.x, p.jointCount);
    float3 t = parent == 0 ? crowdRoot(roots, slot) : joint.local.xyz;
    while (parent != 0) {
        uint j = parent - 1;
        CrowdJoint up = joints[p.jointBase + j];
        parent = as_type<uint>(up.local.w);
        float4 uq = crowdRotation(rotations, slot, j, p.jointCount);
        t = quatRotate(uq, t) + (parent == 0 ? crowdRoot(roots, slot) : up.local.xyz);
        q = quatMul(uq, q);
    }
    // Posed joint x inverse bind: a bind-pose vertex into the joint's space, then to where the joint is now.
    t = quatRotate(q, joint.inverseBindTranslation.xyz) + t;
    q = quatMul(q, joint.inverseBindRotation);
    float3 x = quatRotate(q, float3(1.0f, 0.0f, 0.0f)), y = quatRotate(q, float3(0.0f, 1.0f, 0.0f));
    float3 z = quatRotate(q, float3(0.0f, 0.0f, 1.0f));
    JointMatrix m;
    m.row0 = float4(x.x, y.x, z.x, t.x);
    m.row1 = float4(x.y, y.y, z.y, t.y);
    m.row2 = float4(x.z, y.z, z.z, t.z);
    palette[(p.firstSlot + gid.y) * p.paletteStride + gid.x] = m;
}

// Linear blend skinning of one vertex of one slot. The slot's positions of last frame are kept first: a hit on a
// deforming mesh finds where its point was (MeshData.prevOffset, traceSurface).
kernel void crowdSkinKernel(constant CrowdSkinParams& p          [[buffer(0)]],
                            device const SkinVertex*  skin       [[buffer(1)]],
                            device const JointMatrix* palette    [[buffer(2)]],
                            device float3*            positions  [[buffer(3)]],
                            device float3*            normals    [[buffer(4)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.vertexCount || gid.y >= p.slotCount) return;
    uint current = p.currentBase + gid.y * p.vertexCount + gid.x;
    positions[p.previousBase + gid.y * p.vertexCount + gid.x] = positions[current];

    SkinVertex v = skin[p.skinBase + gid.x];
    float4 bind = float4(positions[p.bindBase + gid.x], 1.0f), normal = float4(normals[p.bindBase + gid.x], 0.0f);
    uint base = (p.firstSlot + gid.y) * p.paletteStride;
    float weights[4] = {v.w0, v.w1, v.w2, 1.0f - v.w0 - v.w1 - v.w2};
    float3 position = float3(0.0f), n = float3(0.0f);
    for (uint k = 0; k < 4; ++k) {
        if (weights[k] == 0.0f) continue;
        JointMatrix m = palette[base + ((v.joints >> (8 * k)) & 0xFFu)];
        position += weights[k] * float3(dot(m.row0, bind), dot(m.row1, bind), dot(m.row2, bind));
        n += weights[k] * float3(dot(m.row0, normal), dot(m.row1, normal), dot(m.row2, normal));
    }
    positions[current] = position;
    normals[current] = normalize(n);
}
