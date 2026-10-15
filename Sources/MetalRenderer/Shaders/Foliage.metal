// ---------------------------------------------------------------------------------------------
// Foliage: the wind (FOLIAGE scenes)
// ---------------------------------------------------------------------------------------------

// A plant in the wind is rigid pieces turning about bones: the whole plant about its foot (the root), a limb about
// where it leaves the trunk, a bough about where it hangs on its limb. A turn is a function of the time, the wind
// and the piece, nothing else: every frame plantWindKernel turns each part's instance in the top-level structure to
// where the wind has it, and the shading turns the hit point the same way (at this frame's time and the last one's,
// for the motion vector). The parts' meshes are never rebuilt.

constant float WIND_ROOT_SWAY = 0.022f;    // radians at full wind: the trunk's lean plus its swing
constant float WIND_COVER_LEAN = 0.2f;     // how far grass and ferns lean at full wind, per unit of their height
constant float WIND_LIMB_SPEED = 1.5f;     // radians per second of a limb's swing; boughs are quicker
constant float WIND_BOUGH_SPEED = 3.4f;

// A sine's shape (period 2 pi, -1...1) from a parabola: the swings need its rhythm, not its exact values, and the
// traversal evaluates several per part it enters.
inline float windWave(float x) {
    float t = fract(x * 0.15915494f) * 2.0f - 1.0f;
    return 4.0f * t * (1.0f - abs(t));
}

// How hard it blows at a place, 0...1: gusts are waves travelling downwind. `wind`: xy = where it blows to (world
// x, z; unit), z = strength, w = gustiness (0 = steady).
inline float windGust(float4 wind, float3 p, float time) {
    float along = dot(wind.xy, p.xz), across = dot(float2(-wind.y, wind.x), p.xz);
    float wave = 0.6f * windWave(along * 0.07f - time * 1.1f + 0.6f * windWave(across * 0.05f))
               + 0.4f * windWave(along * 0.19f - time * 2.3f + across * 0.11f);
    return mix(1.0f, 0.5f + 0.5f * wave, wind.w);
}

// The plants share their parts' turns: an assembly's parts are posed for PLANT_PHASES phases of the wind (its variants,
// PlantTracing.swift: plantWindKernel), and a plant takes the variant of its phase's bucket. The whole plant's turn
// about its foot is its own (its instance's transform). The parts swing with the forest's mean gust.
constant uint PLANT_PHASES = 8;

struct PlantWind {
    float3 axis;      // the root turns about this, through the plant's origin (plant space, unit)
    float  angle;
    float  gust;      // windGust at the plant
    float  phase;     // the plant's own, so that no two swing together
    float  time;
    float  boneGust;  // what its parts' bones swing with: the mean gust, and its phase bucket's phase (bonePhase)
    float  bonePhase;
};

// The mean of windGust over its waves: what the shared bones swing with.
inline float meanGust(float4 wind) { return 1.0f - 0.5f * wind.w; }
// The phase of a plant's bucket: its variant's.
inline float bucketPhase(uint bucket) { return (float(bucket) + 0.5f) * (6.2831853f / float(PLANT_PHASES)); }
// A plant's phase bucket, from its id (the hash plantWind takes its phase from).
inline uint plantBucket(uint instance) { return ((pcgHash(instance + 0x5EEDu) & 0xFFFFu) * PLANT_PHASES) >> 16; }

// A plant's wind from its world -> plant rows (InstanceData.normalMatrix's columns): a rotation, a
// uniform scale and a translation, so the plant's place in the world can be read back from them.
inline PlantWind plantWind(float4 wind, float time, float4 row0, float4 row1, float4 row2, uint instance) {
    PlantWind w;
    float3 origin = -(row0.xyz * row0.w + row1.xyz * row1.w + row2.xyz * row2.w) / dot(row0.xyz, row0.xyz);
    float3 to = float3(wind.x, 0.0f, wind.y);
    float3 downwind = float3(dot(row0.xyz, to), dot(row1.xyz, to), dot(row2.xyz, to));
    float3 axis = cross(float3(0.0f, 1.0f, 0.0f), downwind);   // plants stand along +y: it leans downwind
    float len = length(axis);
    w.axis = len > 1e-6f ? axis / len : float3(1.0f, 0.0f, 0.0f);
    w.phase = float(pcgHash(instance + 0x5EEDu) & 0xFFFFu) * (6.2831853f / 65536.0f);
    w.gust = windGust(wind, origin, time);
    w.time = time;
    w.angle = wind.z * WIND_ROOT_SWAY * w.gust * (0.55f + 0.45f * windWave(time * 1.3f + w.phase));
    w.boneGust = meanGust(wind);
    w.bonePhase = bucketPhase(plantBucket(instance));
    return w;
}

// A bone's turn: `pivotAngle.w` = the most it turns (at full wind), `axisPhase.w` = its phase; `gust` and `phase`
// are its plant's (PlantWind).
inline float boneAngle(float4 pivotAngle, float4 axisPhase, float gust, float phase, float time, float strength, float speed) {
    float p = axisPhase.w + phase;
    float f = speed * (0.75f + 0.5f * fract(axisPhase.w * 7.31f));
    return strength * pivotAngle.w * gust * (0.65f * windWave(time * f + p) + 0.35f * windWave(time * f * 2.37f + 1.7f * p));
}

// v turned by `angle` about the unit `axis` (Rodrigues). The turns are small (under 0.2 rad): the sine and cosine
// are their series, good to 1e-6 there.
inline float3 windTurn(float3 v, float3 axis, float angle) {
    float a2 = angle * angle;
    float s = angle * (1.0f - a2 * (1.0f / 6.0f)), oneMinusC = a2 * (0.5f - a2 * (1.0f / 24.0f));
    return v + cross(axis, v) * s + (axis * dot(axis, v) - v) * oneMinusC;
}
inline float3 windTurn(float3 p, float3 pivot, float3 axis, float angle) { return pivot + windTurn(p - pivot, axis, angle); }

// Ground cover (grass, ferns) has no bones: a patch leans as a whole, each point downwind by its height times this
// (object space, level: the patch stands along +y): a shear, which its instance's transform carries every frame
// (PlantTracing.swift), and the shading applies to the hit point too. The swing is a wave travelling
// downwind, not the patch's own, so neighbouring patches move together. `row0...2`: world -> object, as for plantWind.
inline float3 coverLean(float4 wind, float time, float4 row0, float4 row1, float4 row2) {
    float3 origin = -(row0.xyz * row0.w + row1.xyz * row1.w + row2.xyz * row2.w) / dot(row0.xyz, row0.xyz);
    float3 to = float3(wind.x, 0.0f, wind.y);
    float2 downwind = float2(dot(row0.xyz, to), dot(row2.xyz, to));
    float swing = 0.6f + 0.4f * windWave(time * 2.6f - dot(wind.xy, origin.xz) * 0.9f);
    float lean = wind.z * WIND_COVER_LEAN * windGust(wind, origin, time) * swing;
    downwind *= lean / max(length(downwind), 1e-6f);
    return float3(downwind.x, 0.0f, downwind.y);
}

// A part of an assembly (a generated plant): a placed mesh in the plant's space, with the bones it turns about.
struct RTPart {
    float4 row0;  // plant -> part rows
    float4 row1;
    float4 row2;
    uint mesh;        // the part's mesh
    uint pad;         // RT_PART_RIGID: a building's part (Scene.Assembly.rigid), which the wind doesn't turn
    uint firstLeaf;   // its triangles from here on take the instance's leaf material (the one after its wood's)
    uint leafCount;   // how many they are, in a shuffled order: autumn drops them from the end (0 = evergreen)
    float4 limb;      // the wind's bones: xyz = pivot (plant space), w = its largest turn, 0 = none
    float4 limbAxis;  // xyz = the turn's axis, w = phase
    float4 bough;     // the bone on the limb (the part itself, if it hangs on one)
    float4 boughAxis;
};
static_assert(sizeof(RTPart) == 128, "RTPart: Scene.Assembly.gpuParts");
constant uint RT_PART_RIGID = 1u;

// A part's point (or direction) turned by its bones (its bough's, then its limb's), in its plant's space.
inline float3 partBones(RTPart part, PlantWind w, float strength, float3 p, bool point) {
    if (part.bough.w != 0.0f) {
        float a = boneAngle(part.bough, part.boughAxis, w.boneGust, w.bonePhase, w.time, strength, WIND_BOUGH_SPEED);
        p = point ? windTurn(p, part.bough.xyz, part.boughAxis.xyz, a) : windTurn(p, part.boughAxis.xyz, a);
    }
    if (part.limb.w != 0.0f) {
        float a = boneAngle(part.limb, part.limbAxis, w.boneGust, w.bonePhase, w.time, strength, WIND_LIMB_SPEED);
        p = point ? windTurn(p, part.limb.xyz, part.limbAxis.xyz, a) : windTurn(p, part.limbAxis.xyz, a);
    }
    return p;
}

// A part's point (or direction) in the wind: from where it is at rest in its plant's space to where it is now.
inline float3 partWind(RTPart part, PlantWind w, float strength, float3 p, bool point) {
    return windTurn(partBones(part, w, strength, p, point), w.axis, w.angle);   // the root: about the plant's origin
}

// A part's point and direction in its plant's space. The part's rows are the inverse (plant -> part) of a rotation,
// a uniform scale and a translation, so its transpose over the squared scale is the way back.
inline float3 partPoint(RTPart part, float3 p) {
    float3 q = p - float3(part.row0.w, part.row1.w, part.row2.w);
    return (part.row0.xyz * q.x + part.row1.xyz * q.y + part.row2.xyz * q.z) / dot(part.row0.xyz, part.row0.xyz);
}
inline float3 partDirection(RTPart part, float3 v) {   // not unit length
    return part.row0.xyz * v.x + part.row1.xyz * v.y + part.row2.xyz * v.z;
}

struct PlantWindParams {
    float4 wind;     // TraceScene.wind
    float  time;
    uint   count;    // descriptors
    uint   stride;   // a descriptor's, in floats
    uint   pad;
};

// The variants' parts in this frame's wind (PlantTracing.swift): each part instance's transform, from its part's
// place in the plant through its bones' turns at its variant's phase. One thread per descriptor; `work` names its
// part and its phase bucket (~0: a pad, which stays). The transforms are MTLIndirectAccelerationStructureInstanceDescriptor's: a packed
// column-major 4x3 matrix at the descriptor's start.
kernel void plantWindKernel(constant PlantWindParams& p      [[buffer(0)]],
                            device const uint2*       work   [[buffer(1)]],
                            device const RTPart*      parts  [[buffer(2)]],
                            device float*             out    [[buffer(3)]],
                            uint gid [[thread_position_in_grid]])
{
    if (gid >= p.count) return;
    uint2 job = work[gid];
    if (job.x == 0xFFFFFFFFu) return;   // a variant's pad
    RTPart part = parts[job.x];
    PlantWind w;
    w.time = p.time;
    w.boneGust = meanGust(p.wind);
    w.bonePhase = bucketPhase(job.y);
    float3 o = partBones(part, w, p.wind.z, partPoint(part, float3(0.0f)), true);
    float3 x = partBones(part, w, p.wind.z, partPoint(part, float3(1.0f, 0.0f, 0.0f)), true) - o;
    float3 y = partBones(part, w, p.wind.z, partPoint(part, float3(0.0f, 1.0f, 0.0f)), true) - o;
    float3 z = partBones(part, w, p.wind.z, partPoint(part, float3(0.0f, 0.0f, 1.0f)), true) - o;
    device float* m = out + gid * p.stride;
    m[0] = x.x; m[1] = x.y; m[2] = x.z;
    m[3] = y.x; m[4] = y.y; m[5] = y.z;
    m[6] = z.x; m[7] = z.y; m[8] = z.z;
    m[9] = o.x; m[10] = o.y; m[11] = o.z;
}

// The share of its leaves a deciduous plant still has when `fall` of all leaves are down: each plant in its own time.
inline float plantKeep(float fall, uint instance) {
    return 1.0f - saturate(fall * 1.6f - 0.6f * float(pcgHash(instance + 0xFA11u) & 0xFFu) * (1.0f / 255.0f));
}
