// ---------------------------------------------------------------------------------------------
// Mip chains under Metal 4 (Metal4Frame.generateMipmaps): each texel of level `from` + 1 is a bilinear sample of level
// `from` at the center of the 2x2 under it, which is what the blit encoder's generateMipmaps makes on Metal 3, bit for
// bit (MipKernelTests; the mean of four reads, rounded to the nearest half, differs in about 1% of texels: the filter
// adds with less precision near ties). Metal 4's own generateMipmaps keeps one texel of the four, and a Metal 3
// command buffer for the blit, in the middle of the frame, left the GPU idle about 0.15 ms a time.
// For the sky's, the water's waves, slopes and caustics: power-of-two squares.
// ---------------------------------------------------------------------------------------------

constexpr sampler mipBilinear(filter::linear, mip_filter::nearest, address::clamp_to_edge, coord::normalized);

kernel void mipDown2DKernel(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            constant uint&                   from [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    uint w = max(src.get_width(from) >> 1, 1u), h = max(src.get_height(from) >> 1, 1u);
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid) + 0.5f) / float2(w, h);   // the 2x2's center
    dst.write(src.sample(mipBilinear, uv, level(float(from))), gid, from + 1);
}

kernel void mipDown2DArrayKernel(texture2d_array<float, access::sample> src [[texture(0)]],
                                 texture2d_array<float, access::write>  dst [[texture(1)]],
                                 constant uint&                         from [[buffer(0)]],
                                 uint3 gid [[thread_position_in_grid]])
{
    uint w = max(src.get_width(from) >> 1, 1u), h = max(src.get_height(from) >> 1, 1u);
    if (gid.x >= w || gid.y >= h) return;
    float2 uv = (float2(gid.xy) + 0.5f) / float2(w, h);
    dst.write(src.sample(mipBilinear, uv, gid.z, level(float(from))), gid.xy, gid.z, from + 1);
}
