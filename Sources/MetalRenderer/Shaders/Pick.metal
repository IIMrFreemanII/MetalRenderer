// Click-to-pick (the Material Designer's, Renderer.encodePick): what the ray through the clicked point meets first,
// one thread: its instance, its material (as the shading finds it: a leaf's, a mesh of several materials' triangle's,
// an SDF shape's node's), the distance, the surface's colour and place. -1 in x: nothing.
struct PickRay {
    float4 origin;
    float4 direction;
};

kernel void pickKernel(constant Uniforms&         u          [[buffer(0)]],
                       SCENE_ACCEL                accel      [[buffer(1)]],
                       device const float3*       positions  [[buffer(2)]],
                       device const float3*       normals    [[buffer(3)]],
                       device const uint*         indices    [[buffer(4)]],
                       device const MeshData*     meshes     [[buffer(5)]],
                       device const InstanceData* instances  [[buffer(6)]],
                       constant SceneShading&     shading    [[buffer(7)]],
                       constant PickRay&          p          [[buffer(9)]],
                       device float4*             out        [[buffer(10)]],
                       uint                       tid        [[thread_position_in_grid]])
{
    if (tid != 0) return;
    SceneData s = sceneData(positions, normals, indices, meshes, instances, shading, nullptr, 0u);
    Ray r = makeRay(p.origin.xyz, p.direction.xyz, 0.0f, INFINITY);
    Hit h = intersectClosest(r, MASK_ALL, accel);
    if (!h.hit) { out[0] = float4(-1.0f); return; }
    InstanceData inst = instanceRecord(s.instances, h.instance);
    uint material = inst.materialIndex;
    if (SDF_SHAPES && h.part == HIT_SDF) {
        material += h.primitive;
    } else if (!(VOXELS && h.part == HIT_VOXEL) && !(HAIR_CURVES && h.part == HIT_CURVE)) {
        HitVertices hv = fetchHitVertices(h, inst, accel, s);
        if (hv.leaf) material += 1u;
        if (MULTI_MATERIAL && hv.triangle != ~0u) material += s.triangleMaterials[hv.triangle];
        if (STREAMED) material += hv.material;
    }
    Surface sf = surfaceFromHit(h, r, accel, s, 0.0f, false);
    out[0] = float4(float(h.instance), float(material), h.distance, 1.0f);
    out[1] = float4(sf.albedo, 0.0f);
    out[2] = float4(sf.position, 0.0f);
}
