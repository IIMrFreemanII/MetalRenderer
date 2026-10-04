// ---------------------------------------------------------------------------------------------
// Foliage: the wind (FOLIAGE scenes, custom ray tracer)
// ---------------------------------------------------------------------------------------------

// A plant in the wind is rigid pieces turning about bones: the whole plant about its foot (the root), a limb about
// where it leaves the trunk, a bough about where it hangs on its limb. A turn is a function of the time, the wind
// and the piece, nothing else: the traversal undoes the turns on the ray as it enters a plant and a part, the
// shading redoes them on the hit point (at this frame's time and the last one's, for the motion vector), and
// nothing is rebuilt. The boxes of the parts and plants are padded by the largest turn (Scene.Flora).

constant float WIND_ROOT_SWAY = 0.022f;    // radians at full wind: the trunk's lean plus its swing
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
