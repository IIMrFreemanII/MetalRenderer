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
    uint faceBase;        // its vertices' first range of face targets (CROWD_NONE: no expressions)
    uint groupBase;       // its vertices' first face group (CROWD_NONE: no face)
    uint faceTargets;     // weights per slot
    float faceScale;      // its head's size against the base's (the targets' movements are the base's)
};
static_assert(sizeof(CrowdSkinParams) == 48, "CrowdSkinParams: CrowdSkinner.SkinParams");

#define CROWD_NONE 0xFFFFFFFFu
#define FACE_GROUPS 6u

// A face's target moving a vertex (FaceRig.Entry): delta.w is the target's index (bits).
struct FaceEntry {
    float4 delta;
    float4 normal;
};
static_assert(sizeof(FaceEntry) == 32, "FaceEntry: FaceRig.Entry");

// A face group's turn this frame (FaceState.Turn): about `pivot` (an eye's centre), by the angle at weight 1.
struct FaceTurn {
    float4 axisAngle;
    float4 pivot;
};
static_assert(sizeof(FaceTurn) == 32, "FaceTurn: FaceState.Turn");

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
// deforming mesh finds where its point was (MeshData.prevOffset, traceSurface). A face's vertex is moved first, in the
// bind pose (CharacterFace.swift): by the slot's expression targets, then turned with its group (an eyeball, a lid).
kernel void crowdSkinKernel(constant CrowdSkinParams& p          [[buffer(0)]],
                            device const SkinVertex*  skin       [[buffer(1)]],
                            device const JointMatrix* palette    [[buffer(2)]],
                            device float3*            positions  [[buffer(3)]],
                            device float3*            normals    [[buffer(4)]],
                            device const uint*        faceRanges [[buffer(5)]],
                            device const FaceEntry*   faceEntries [[buffer(6)]],
                            device const float*       faceWeights [[buffer(7)]],
                            device const uint*        faceGroups [[buffer(8)]],
                            device const FaceTurn*    faceTurns  [[buffer(9)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.vertexCount || gid.y >= p.slotCount) return;
    uint current = p.currentBase + gid.y * p.vertexCount + gid.x;
    positions[p.previousBase + gid.y * p.vertexCount + gid.x] = positions[current];

    SkinVertex v = skin[p.skinBase + gid.x];
    float3 bindPosition = positions[p.bindBase + gid.x], bindNormal = normals[p.bindBase + gid.x];
    uint slot = p.firstSlot + gid.y;
    if (p.faceBase != CROWD_NONE) {
        uint first = faceRanges[p.faceBase + gid.x], last = faceRanges[p.faceBase + gid.x + 1];
        device const float* w = faceWeights + slot * p.faceTargets;
        for (uint e = first; e < last; ++e) {
            FaceEntry f = faceEntries[e];
            float k = w[as_type<uint>(f.delta.w)];
            bindPosition += (k * p.faceScale) * f.delta.xyz;
            bindNormal += k * f.normal.xyz;
        }
        bindNormal = normalize(bindNormal);
    }
    if (p.groupBase != CROWD_NONE) {
        uint g = faceGroups[p.groupBase + gid.x];
        if ((g & 0xFFu) != 0u) {
            FaceTurn t = faceTurns[slot * FACE_GROUPS + (g & 0xFFu) - 1u];
            float angle = t.axisAngle.w * float(g >> 8) / 255.0f;
            float4 q = float4(t.axisAngle.xyz * sin(0.5f * angle), cos(0.5f * angle));
            bindPosition = t.pivot.xyz + quatRotate(q, bindPosition - t.pivot.xyz);
            bindNormal = quatRotate(q, bindNormal);
        }
    }
    float4 bind = float4(bindPosition, 1.0f), normal = float4(bindNormal, 0.0f);
    uint base = slot * p.paletteStride;
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

// ---------------------------------------------------------------------------------------------
// Hair (CharacterHair.swift): a groom's strands on a pose slot, after its skinning. A strand's root is a point of one
// of the slot's triangles; its control points are offsets from the root, turned by the head's bone (scalp hair) or by
// the triangle's frame (brows, lashes, beard: they follow the expressions), scaled by the head's size. Written into the
// groom's curve mesh with a phantom point before and after (a Catmull-Rom curve passes through the rest), last frame's
// kept first (prevOffset). CharacterHair.place is the same on the CPU.
// ---------------------------------------------------------------------------------------------

struct CrowdHairParams {
    uint firstStrand;     // the groom's first root (CrowdHairRoot) and offset (per strand `perStrand` of them)
    uint strandCount;
    uint perStrand;
    uint firstOffset;
    uint curveBase;       // the curve mesh's first control point
    uint prevOffset;      // ...and last frame's, that far on
    uint slotBase;        // the slot's first vertex (its skinned positions)
    uint palette;         // the head joint's skinning matrix
    float scale;          // the head's size against the base's
    uint followsHead;
    uint pad0, pad1;
};
static_assert(sizeof(CrowdHairParams) == 48, "CrowdHairParams: CrowdSkinner.HairParams");

struct CrowdHairRoot {
    uint4  vertices;      // the triangle's corners (the slot's vertices)
    float4 bary;          // xy: the second and third corners' weights
};

kernel void crowdHairKernel(constant CrowdHairParams&   p        [[buffer(0)]],
                            device const CrowdHairRoot* roots    [[buffer(1)]],
                            device const float4*        offsets  [[buffer(2)]],
                            device const JointMatrix*   palette  [[buffer(3)]],
                            device float3*              positions [[buffer(4)]],
                            uint s [[thread_position_in_grid]])
{
    if (s >= p.strandCount) return;
    CrowdHairRoot r = roots[p.firstStrand + s];
    float3 p0 = positions[p.slotBase + r.vertices.x], p1 = positions[p.slotBase + r.vertices.y], p2 = positions[p.slotBase + r.vertices.z];
    float3 root = p0 * (1.0f - r.bary.x - r.bary.y) + p1 * r.bary.x + p2 * r.bary.y;
    float3 fx, fy, fz;
    if (p.followsHead != 0u) {
        JointMatrix m = palette[p.palette];
        fx = float3(m.row0.x, m.row1.x, m.row2.x);
        fy = float3(m.row0.y, m.row1.y, m.row2.y);
        fz = float3(m.row0.z, m.row1.z, m.row2.z);
    } else {
        fx = normalize(p1 - p0);
        fz = normalize(cross(p1 - p0, p2 - p0));
        fy = cross(fz, fx);
    }
    uint n = p.perStrand, base = p.curveBase + s * (n + 2);
    for (uint i = 0; i < n + 2; ++i) positions[base + i + p.prevOffset] = positions[base + i];
    float3 a = float3(0.0f), b = float3(0.0f), y = float3(0.0f), z = float3(0.0f);
    for (uint i = 0; i < n; ++i) {
        float3 o = offsets[p.firstOffset + s * n + i].xyz * p.scale;
        float3 x = root + fx * o.x + fy * o.y + fz * o.z;
        positions[base + 1 + i] = x;
        if (i == 0) a = x;
        if (i == 1) b = x;
        if (i == n - 2) y = x;
        if (i == n - 1) z = x;
    }
    positions[base] = 2.0f * a - b;
    positions[base + n + 1] = 2.0f * z - y;
}
