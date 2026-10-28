// Fabrics' sheen (the Garment Designer's, Fabric.swift): the fibres standing out of a cloth's surface catch light at
// grazing angles, so its silhouette and folds turned away glow lighter (velvet, knits, brushed cotton) while seen face
// on it is its colour. Every lighting path takes the hit's albedo: the sheen is folded into it, from the view, as an
// albedo that rises toward grazing (an inverted-Gaussian lobe as Ashikhmin's velvet, in 1 - |n.v|) and is tinted
// toward white; energy is kept by darkening the face-on colour by the lobe's mean.

// The sheen and its spread packed in a material's metallic lane (Scene.addFabricMaterial): -(1 + q/256 + r/65536),
// q and r 0...255.
inline float2 fabricSheen(float packed) {
    float x = (-packed - 1.0f) * 256.0f;
    float q = floor(x);
    return float2(q / 255.0f, saturate((x - q) * 256.0f / 255.0f));
}

inline void applySheen(thread Surface& sf, float3 dir) {
    float c = saturate(abs(dot(sf.normal, -dir)));
    float spread = mix(0.12f, 0.6f, sf.sheen.y);
    // How grazing: 0 face on, 1 edge on, its lobe's width the spread.
    float g = 1.0f - c;
    float lobe = exp(-(c * c) / (spread * spread)) * 0.85f + 0.15f * g * g * g;
    float3 tint = mix(sf.albedo, float3(1.0f), 0.55f);
    float k = sf.sheen.x;
    sf.albedo = sf.albedo * (1.0f - 0.25f * k * spread) + tint * (k * 0.6f * lobe);
}
