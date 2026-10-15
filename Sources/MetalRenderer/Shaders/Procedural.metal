// Procedural materials as code (the Material Designer's shader-code mode, MatShaderCode): `proceduralMaterial(program,
// uv, P)` gives a shading point the channels its graph computes there (PROCEDURAL_CODE scenes, Surface.metal). Until a
// scene has such materials it is the stand-in below; their programs are spliced in at the marker (Pipelines.compile:
// the scene's MatShaderCode.splice), with MaterialShaders' functions.
struct ProcSample {
    float4 base;       // base colour (sRGB values)
    float4 orm;        // occlusion, roughness, metallic
    float4 normal;     // tangent space, encoded as the renderer's normal maps are
    float4 emissive;   // sRGB values
    uint has;          // bits: base, orm, normal, emissive
};

inline float3 procLinear(float3 c) { return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f); }

// @procedural-code
#ifndef MAT_PROCEDURAL
inline ProcSample proceduralMaterial(uint program, float2 uv, device const float4* P) {
    ProcSample s = { float4(0.5f), float4(1, 0.5f, 0, 1), float4(0.5f, 0.5f, 1, 1), float4(0.0f), 0u };
    return s;
}
#endif
