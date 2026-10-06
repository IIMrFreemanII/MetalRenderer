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

struct PlantWind {
    float3 axis;    // the root turns about this, through the plant's origin (plant space, unit)
    float  angle;
    float  gust;    // windGust at the plant
    float  phase;   // the plant's own, so that no two swing together
    float  time;
};

// A plant's wind from its world -> plant rows (RTInstance's, InstanceData.normalMatrix's columns): a rotation, a
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
// (object space, level: the patch stands along +y). A shear is undone exactly by the opposite one, so the traversal
// shears the ray back as it enters the patch, as it turns it back for a plant. The swing is a wave travelling
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
    uint pad;
    uint firstLeaf;   // its triangles from here on take the instance's leaf material (the one after its wood's)
    uint leafCount;   // how many they are, in a shuffled order: autumn drops them from the end (0 = evergreen)
    float4 limb;      // the wind's bones: xyz = pivot (plant space), w = its largest turn, 0 = none
    float4 limbAxis;  // xyz = the turn's axis, w = phase
    float4 bough;     // the bone on the limb (the part itself, if it hangs on one)
    float4 boughAxis;
};
static_assert(sizeof(RTPart) == 128, "RTPart: Scene.Assembly.gpuParts");

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

// The share of its leaves a deciduous plant still has when `fall` of all leaves are down: each plant in its own time.
inline float plantKeep(float fall, uint instance) {
    return 1.0f - saturate(fall * 1.6f - 0.6f * float(pcgHash(instance + 0xFA11u) & 0xFFu) * (1.0f / 255.0f));
}
