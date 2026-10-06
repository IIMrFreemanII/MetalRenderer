// ---------------------------------------------------------------------------------------------
// Hair: how a strand (HAIR_CURVES: a curve whose material is hair, Material.params.z < 0) scatters light.
// ---------------------------------------------------------------------------------------------

// Chiang et al. 2016, "A Practical and Controllable Hair and Fur Model for Production Path Tracing", as pbrt-v3's
// HairBSDF: a dielectric cylinder whose light comes back off its cuticle (R), through it (TT), through and back off
// its far wall (TRT), and the rest in the residual lobe; each lobe a longitudinal spread M_p (scaled by the cuticle's
// tilt alpha) x the light it carries A_p (Fresnel, the pigment's absorption) x an azimuthal spread N_p (a trimmed
// logistic about where a perfect cylinder sends it). Its colour is the pigment's (sigma_a from the colour the strand
// should look, Chiang's fit), its roughnesses fixed here (the G-buffer keeps no more of it). HairBSDF.swift is the
// same on the CPU (HairTests check its energy).
constant float HAIR_BETA_M = 0.3f;      // longitudinal roughness
constant float HAIR_BETA_N = 0.3f;      // azimuthal roughness
constant float HAIR_ALPHA = 0.0349f;    // the cuticle's tilt (2 degrees)
constant float HAIR_ETA = 1.55f;        // keratin's index of refraction
constant float HAIR_MIN_ALBEDO = 0.02f; // its colour (the G-buffer's albedo) is no darker: the light is divided by it
// A shadow ray toward a light behind the strand starts this far along it (m): out of the strand's own curve, which
// it would otherwise meet. (The G-buffer keeps no radius; the scene's strands are thinner than this across.)
constant float HAIR_SHADOW_SKIP = 0.002f;

// A hit on a strand, as the lights see it: its tangent, the direction to the viewer, where across the strand the
// view ray met it (h, -1...1: pbrt's offset), and its colour.
struct HairPoint {
    bool   on;
    float3 tangent;
    float3 view;
    float  h;
    float3 albedo;
};

inline HairPoint noHair() {
    HairPoint hp;
    hp.on = false;
    hp.tangent = hp.view = hp.albedo = float3(0.0f);
    hp.h = 0.0f;
    return hp;
}

// The G-buffer's hair: the tangent octahedral, x in albedo.a and y + 2 in geoNormal.w (0: not hair), what every
// kernel that lights the visible surface reads anyway. h comes back from the shading normal (it faces the viewer on a
// strand: a ray meets a round curve on its near side).
inline float2 hairOctEncode(float3 t) {
    t /= abs(t.x) + abs(t.y) + abs(t.z);
    float2 e = t.z >= 0.0f ? t.xy : (1.0f - abs(t.yx)) * select(float2(-1.0f), float2(1.0f), t.xy >= 0.0f);
    return e;
}
inline float3 hairOctDecode(float2 e) {
    float3 t = float3(e, 1.0f - abs(e.x) - abs(e.y));
    if (t.z < 0.0f) t.xy = (1.0f - abs(t.yx)) * select(float2(-1.0f), float2(1.0f), t.xy >= 0.0f);
    return normalize(t);
}
inline HairPoint hairFromGBuffer(float4 albedo, float geoW, float3 n, float3 view) {
    HairPoint hp = noHair();
    if (geoW < 0.5f) return hp;
    hp.on = true;
    hp.tangent = hairOctDecode(float2(albedo.a, geoW - 2.0f));
    hp.view = view;
    hp.h = hairOffset(n, hp.tangent, view);
    hp.albedo = max(albedo.rgb, float3(HAIR_MIN_ALBEDO));
    return hp;
}

inline float hairI0(float x) {
    float val = 0.0f, x2i = 1.0f, ifact = 1.0f, i4 = 1.0f;
    for (int i = 0; i < 10; ++i) {
        if (i > 1) ifact *= float(i);
        val += x2i / (i4 * ifact * ifact);
        x2i *= x * x;
        i4 *= 4.0f;
    }
    return val;
}
inline float hairLogI0(float x) {
    return x > 12.0f ? x + 0.5f * (-log(2.0f * M_PI_F) + log(1.0f / x) + 1.0f / (8.0f * x)) : log(hairI0(x));
}
inline float hairMp(float cosThetaI, float cosThetaO, float sinThetaI, float sinThetaO, float v) {
    float a = cosThetaI * cosThetaO / v, b = sinThetaI * sinThetaO / v;
    return v <= 0.1f ? exp(hairLogI0(a) - b - 1.0f / v + 0.6931f + log(1.0f / (2.0f * v)))
                     : exp(-b) * hairI0(a) / (sinh(1.0f / v) * 2.0f * v);
}
inline float hairFresnel(float cosI, float eta) {
    cosI = clamp(cosI, -1.0f, 1.0f);
    float sinI = sqrt(max(1.0f - cosI * cosI, 0.0f)), sinT = sinI / eta;
    if (sinT >= 1.0f) return 1.0f;
    float cosT = sqrt(max(1.0f - sinT * sinT, 0.0f));
    float par = (eta * cosI - cosT) / (eta * cosI + cosT), perp = (cosI - eta * cosT) / (cosI + eta * cosT);
    return 0.5f * (par * par + perp * perp);
}
inline float hairLogistic(float x, float s) {
    x = abs(x);
    float e = exp(-x / s);
    return e / (s * (1.0f + e) * (1.0f + e));
}
inline float hairLogisticCDF(float x, float s) { return 1.0f / (1.0f + exp(-x / s)); }
inline float hairNp(float phi, float p, float s, float gammaO, float gammaT) {
    float dphi = phi - (2.0f * p * gammaT - 2.0f * gammaO + p * M_PI_F);
    dphi -= 2.0f * M_PI_F * floor((dphi + M_PI_F) / (2.0f * M_PI_F));   // into -pi...pi
    return hairLogistic(dphi, s) / (hairLogisticCDF(M_PI_F, s) - hairLogisticCDF(-M_PI_F, s));
}
// The pigment's absorption for a strand that should look `c` (Chiang et al.'s fit, for the azimuthal roughness).
inline float3 hairSigmaA(float3 c) {
    float b = HAIR_BETA_N, b2 = b * b;
    float d = 5.969f - 0.215f * b + 2.532f * b2 - 10.73f * b2 * b + 5.574f * b2 * b2 + 0.245f * b2 * b2 * b;
    float3 l = log(max(c, float3(1e-4f))) / d;
    return l * l;
}

// What the strand sends toward the viewer of light from direction `wi` that would light a surface facing it with
// irradiance E: E x this (pbrt's f x |cos theta_i|, the sum of the lobes).
inline float3 hairScatter(HairPoint hp, float3 wi) {
    // The strand's frame: x along it, y the view across it (phi_o = 0), z = x cross y.
    float3 x = hp.tangent;
    float3 y = hp.view - x * dot(hp.view, x);
    y = length_squared(y) > 1e-10f ? normalize(y) : (abs(x.y) < 0.9f ? normalize(cross(x, float3(0, 1, 0))) : normalize(cross(x, float3(1, 0, 0))));
    float3 z = cross(x, y);
    float sinThetaO = clamp(dot(hp.view, x), -1.0f, 1.0f), cosThetaO = sqrt(max(1.0f - sinThetaO * sinThetaO, 0.0f));
    float sinThetaI = clamp(dot(wi, x), -1.0f, 1.0f), cosThetaI = sqrt(max(1.0f - sinThetaI * sinThetaI, 0.0f));
    float phi = atan2(dot(wi, z), dot(wi, y));
    float h = hp.h, gammaO = asin(clamp(h, -1.0f, 1.0f));
    float sinThetaT = sinThetaO / HAIR_ETA, cosThetaT = sqrt(max(1.0f - sinThetaT * sinThetaT, 0.0f));
    float etap = sqrt(max(HAIR_ETA * HAIR_ETA - sinThetaO * sinThetaO, 0.0f)) / max(cosThetaO, 1e-4f);
    float sinGammaT = clamp(h / etap, -1.0f, 1.0f), cosGammaT = sqrt(max(1.0f - sinGammaT * sinGammaT, 0.0f));
    float gammaT = asin(sinGammaT);
    float3 T = exp(-hairSigmaA(hp.albedo) * (2.0f * cosGammaT / max(cosThetaT, 1e-4f)));
    // A_p.
    float f = hairFresnel(cosThetaO * sqrt(max(1.0f - h * h, 0.0f)), HAIR_ETA);
    float3 a0 = float3(f), a1 = (1.0f - f) * (1.0f - f) * T, a2 = a1 * T * f;
    float3 a3 = a2 * f * T / max(float3(1.0f) - T * f, float3(1e-4f));
    // The lobes' longitudinal variances and the azimuthal scale.
    float bm = HAIR_BETA_M, bm2 = bm * bm;
    float v0 = 0.726f * bm + 0.812f * bm2 + 3.7f * pow(bm, 20.0f);
    v0 *= v0;
    float bn = HAIR_BETA_N;
    float s = 0.626657069f * (0.265f * bn + 1.194f * bn * bn + 5.372f * pow(bn, 22.0f));   // sqrt(pi / 8)
    // The cuticle's tilt: the R lobe's theta_o shifted by 2 alpha one way, TT's by alpha the other, TRT's 4 alpha.
    float s1 = sin(HAIR_ALPHA), c1 = sqrt(1.0f - s1 * s1);
    float s2 = 2.0f * c1 * s1, c2 = c1 * c1 - s1 * s1;
    float s4 = 2.0f * c2 * s2, c4 = c2 * c2 - s2 * s2;
    float sinR = sinThetaO * c2 - cosThetaO * s2, cosR = abs(cosThetaO * c2 + sinThetaO * s2);
    float sinTT = sinThetaO * c1 + cosThetaO * s1, cosTT = abs(cosThetaO * c1 - sinThetaO * s1);
    float sinTRT = sinThetaO * c4 + cosThetaO * s4, cosTRT = abs(cosThetaO * c4 - sinThetaO * s4);
    float3 sum = hairMp(cosThetaI, cosR, sinThetaI, sinR, v0) * a0 * hairNp(phi, 0.0f, s, gammaO, gammaT)
               + hairMp(cosThetaI, cosTT, sinThetaI, sinTT, 0.25f * v0) * a1 * hairNp(phi, 1.0f, s, gammaO, gammaT)
               + hairMp(cosThetaI, cosTRT, sinThetaI, sinTRT, 4.0f * v0) * a2 * hairNp(phi, 2.0f, s, gammaO, gammaT)
               + hairMp(cosThetaI, cosThetaO, sinThetaI, sinThetaO, 4.0f * v0) * a3 / (2.0f * M_PI_F);
    return max(sum, float3(0.0f));
}

// What the lobes above leave out: the light that has gone through and off other strands before it reaches the eye,
// most of a head's or a pelt's colour (Chiang's colour mapping assumes a path tracer gathers it). Here it is a stand-in
// (Kajiya-Kay's diffuse: the strand's colour x the sine of the light's angle to it), HAIR_MULTIPLE of a Lambert
// surface's light.
constant float HAIR_MULTIPLE = 0.7f;
inline float3 hairMultiple(HairPoint hp, float3 wi) {
    float c = dot(wi, hp.tangent);
    return hp.albedo * (HAIR_MULTIPLE * sqrt(max(1.0f - c * c, 0.0f)) / M_PI_F);
}

// The direction from p toward a light (its centre; the sun's axis).
inline float3 hairLightDirection(Light light, float3 p) {
    return lightType(light) == LIGHT_SUN ? light.axis.xyz : normalize(light.positionRadius.xyz - p);
}

// A light's light on a strand, unshadowed, as lightUnshadowed gives a surface's: the lobes and the multiple scattering's
// stand-in, albedo divided out (the composite multiplies the strand's colour back).
inline float3 hairUnshadowed(Light light, float3 p, HairPoint hp) {
    float3 l = hairLightDirection(light, p);
    float3 facing = lightUnshadowed(light, p, l, l) * M_PI_F;   // irradiance on a surface facing the light
    return facing * (hairScatter(hp, l) + hairMultiple(hp, l)) / hp.albedo;
}

// lightUnshadowed for any surface: a strand's by its BSDF.
inline float3 litUnshadowed(Light light, float3 p, float3 n, float3 ng, HairPoint hp) {
    return hp.on ? hairUnshadowed(light, p, hp) : lightUnshadowed(light, p, n, ng);
}

// Where a shadow ray from a strand's point toward `target` starts: off its surface on the near side, or past the
// strand when the light is behind it (light through the strand: TT).
inline float3 hairShadowOrigin(float3 position, float3 n, float3 target) {
    float3 l = normalize(target - position);
    return dot(l, n) >= 0.0f ? position + n * RAY_EPSILON : position + l * HAIR_SHADOW_SKIP;
}

// A shadow ray's start toward `target` for a surface at `position` (`p`: already off it): a strand's own
// (hairShadowOrigin), else `p`.
inline float3 hairOrSurface(HairPoint hp, float3 position, float3 n, float3 p, float3 target) {
    return hp.on ? hairShadowOrigin(position, n, target) : p;
}
