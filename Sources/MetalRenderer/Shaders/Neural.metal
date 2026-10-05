// ---------------------------------------------------------------------------------------------
// Our own denoising upscaler (NeuralUpscaler.swift; trained by Tools/neural, whose model.py is the reference for
// every kernel here): a recurrent U-Net at the render resolution, padded to a multiple of 4, over the frame's noisy
// light and guides plus last frame's output and state, warped by the motion and folded into the render resolution.
// Tensors are half, planar: channel c of a W x H tensor starts at c * W * H. Weights keep PyTorch's [out][in][ky][kx].
// ---------------------------------------------------------------------------------------------

struct NeuralParams {
    uint4  size;       // x, y: this dispatch's tensor width, height; z, w: the frame's render width, height (unpadded)
    uint4  channels;   // x: input 0's, y: input 1's (concatenated after it), z: output's, w: NEURAL_* flags
    float4 frame;      // x: exposure, y, z: jitter (render pixels)
    uint4  shape;      // x: upscale factor, y: state channels (3 colour + hidden), z, w: output width, height (unpadded)
};

constant uint NEURAL_RELU     = 1;   // conv: ReLU after the bias
constant uint NEURAL_UPSAMPLE = 2;   // conv: input 0 is at half this resolution (nearest 2x upsampling)
constant uint NEURAL_RESET    = 4;   // warp: no history (zeros)

// Last frame's output and state (output resolution) moved to this frame: each output pixel reads, bilinearly with
// clamped edges, last frame's at its position plus the motion of the render pixel under it (model.py's warp).
kernel void neuralWarpKernel(constant NeuralParams&         p       [[buffer(0)]],
                             device const half*             state   [[buffer(1)]],
                             device half*                   warped  [[buffer(2)]],
                             texture2d<float, access::read> motion  [[texture(0)]],
                             uint2 q [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h, f = p.shape.x;
    if (q.x >= w || q.y >= h) return;
    uint i = q.y * w + q.x;
    if (p.channels.w & NEURAL_RESET) {
        for (uint c = 0; c < p.shape.y; c++) warped[c * n + i] = 0.0h;
        return;
    }
    uint2 r = min(q / f, p.size.zw - 1);
    float2 u = clamp(float2(q) + motion.read(r).xy * float(f), float2(0.0f), float2(w - 1, h - 1));
    uint2 a = uint2(u), b = min(a + 1, uint2(w - 1, h - 1));
    float2 t = u - float2(a);
    uint i00 = a.y * w + a.x, i01 = a.y * w + b.x, i10 = b.y * w + a.x, i11 = b.y * w + b.x;
    for (uint c = 0; c < p.shape.y; c++) {
        device const half* s = state + c * n;
        float top = mix(float(s[i00]), float(s[i01]), t.x), bottom = mix(float(s[i10]), float(s[i11]), t.x);
        warped[c * n + i] = half(mix(top, bottom, t.y));
    }
}

// The U-Net's input at the render resolution: the guides (model.py's prepare; padding repeats the edge pixels), the
// jitter, and the warped history folded in (pixel_unshuffle: channel c * f*f + i * f + j holds output pixel
// (f * x + j, f * y + i) of channel c).
kernel void neuralPrepareKernel(constant NeuralParams&         p         [[buffer(0)]],
                                device const half*             warped    [[buffer(1)]],
                                device half*                   x         [[buffer(2)]],
                                texture2d<float, access::read> color     [[texture(0)]],
                                texture2d<float, access::read> albedo    [[texture(1)]],
                                texture2d<float, access::read> specular  [[texture(2)]],
                                texture2d<float, access::read> normal    [[texture(3)]],
                                texture2d<float, access::read> roughness [[texture(4)]],
                                uint2 tid [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h, f = p.shape.x;
    if (tid.x >= w || tid.y >= h) return;
    uint2 s = min(tid, p.size.zw - 1);
    float4 nd = normal.read(s);
    float v[16];
    float3 c = log(1.0f + max(color.read(s).rgb, 0.0f) * p.frame.x), a = albedo.read(s).rgb, sp = specular.read(s).rgb;
    v[0] = c.x; v[1] = c.y; v[2] = c.z;
    v[3] = a.x; v[4] = a.y; v[5] = a.z;
    v[6] = sp.x; v[7] = sp.y; v[8] = sp.z;
    v[9] = nd.x; v[10] = nd.y; v[11] = nd.z;
    v[12] = nd.w > 0.0f ? 1.0f / (1.0f + nd.w) : 0.0f;   // sky: 0
    v[13] = roughness.read(s).r;
    v[14] = p.frame.y; v[15] = p.frame.z;
    uint i = tid.y * w + tid.x;
    for (uint k = 0; k < 16; k++) x[k * n + i] = half(v[k]);
    uint ow = w * f, on = n * f * f;
    for (uint ch = 0; ch < p.shape.y; ch++) {
        for (uint dy = 0; dy < f; dy++) {
            for (uint dx = 0; dx < f; dx++) {
                x[(16 + ch * f * f + dy * f + dx) * n + i] = warped[ch * on + (tid.y * f + dy) * ow + tid.x * f + dx];
            }
        }
    }
}

// 3x3 convolution, zero padded, four output channels a thread. Input 1's channels follow input 0's (the U-Net's
// skip connections); input 0 can be at half the resolution, read as if upsampled by repeating each pixel.
kernel void neuralConvKernel(constant NeuralParams& p       [[buffer(0)]],
                             device const half*     in0     [[buffer(1)]],
                             device const half*     in1     [[buffer(2)]],
                             device const half*     weights [[buffer(3)]],
                             device const half*     bias    [[buffer(4)]],
                             device half*           out     [[buffer(5)]],
                             uint3 tid [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h;
    uint co = tid.z * 4;
    if (tid.x >= w || tid.y >= h || co >= p.channels.z) return;
    uint c0 = p.channels.x, cin = c0 + p.channels.y;
    bool up = p.channels.w & NEURAL_UPSAMPLE;
    uint w0 = up ? w / 2 : w, n0 = up ? n / 4 : n;
    float4 acc = float4(bias[co], bias[co + 1], bias[co + 2], bias[co + 3]);
    uint stride = cin * 9;   // one output channel's weights
    for (int ky = 0; ky < 3; ky++) {
        int y = int(tid.y) + ky - 1;
        if (y < 0 || y >= int(h)) continue;
        for (int kx = 0; kx < 3; kx++) {
            int x = int(tid.x) + kx - 1;
            if (x < 0 || x >= int(w)) continue;
            uint k = uint(ky * 3 + kx);
            uint i0 = up ? uint(y / 2) * w0 + uint(x / 2) : uint(y) * w + uint(x), i1 = uint(y) * w + uint(x);
            for (uint ci = 0; ci < cin; ci++) {
                float v = ci < c0 ? float(in0[ci * n0 + i0]) : float(in1[(ci - c0) * n + i1]);
                uint wi = co * stride + ci * 9 + k;
                acc += v * float4(weights[wi], weights[wi + stride], weights[wi + 2 * stride], weights[wi + 3 * stride]);
            }
        }
    }
    if (p.channels.w & NEURAL_RELU) acc = max(acc, 0.0f);
    uint i = tid.y * w + tid.x;
    for (uint k = 0; k < 4; k++) out[(co + k) * n + i] = half(acc[k]);
}

// 2x2 max pooling: `size` is the output's (half the input's), channels.z its channels.
kernel void neuralPoolKernel(constant NeuralParams& p   [[buffer(0)]],
                             device const half*     in  [[buffer(1)]],
                             device half*           out [[buffer(2)]],
                             uint3 tid [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y;
    if (tid.x >= w || tid.y >= h || tid.z >= p.channels.z) return;
    uint iw = w * 2, base = tid.z * w * h * 4 + tid.y * 2 * iw + tid.x * 2;
    half m = max(max(in[base], in[base + 1]), max(in[base + iw], in[base + iw + 1]));
    out[tid.z * w * h + tid.y * w + tid.x] = m;
}

// The head's output unfolded to the output resolution (pixel_shuffle) and applied: a blend between the warped history
// and the new colour (log light), and the new state. Writes the state over last frame's (the warp has read it) and the
// linear light before exposure, which tonemapKernel then shows.
kernel void neuralFinishKernel(constant NeuralParams&          p       [[buffer(0)]],
                               device const half*              head    [[buffer(1)]],
                               device const half*              warped  [[buffer(2)]],
                               device half*                    state   [[buffer(3)]],
                               texture2d<float, access::write> output  [[texture(0)]],
                               uint2 q [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h, f = p.shape.x;
    if (q.x >= w || q.y >= h) return;
    uint rw = w / f, rn = n / (f * f);
    uint ri = (q.y / f) * rw + q.x / f, sub = (q.y % f) * f + q.x % f;
    device const half* cell = head + sub * rn + ri;   // channel c of this output pixel: cell[c * f * f * rn]
    uint step = f * f * rn;
    uint i = q.y * w + q.x;
    float alpha = 1.0f / (1.0f + exp(-float(cell[0])));
    float3 history = float3(warped[i], warped[n + i], warped[2 * n + i]);
    float3 fresh = float3(cell[step], cell[2 * step], cell[3 * step]);
    float3 o = max(alpha * history + (1.0f - alpha) * fresh, 0.0f);
    for (uint c = 0; c < 3; c++) state[c * n + i] = half(o[c]);
    for (uint c = 3; c < p.shape.y; c++) state[c * n + i] = half(precise::tanh(float(cell[(c + 1) * step])));
    if (q.x < p.shape.z && q.y < p.shape.w) output.write(float4((exp(o) - 1.0f) / p.frame.x, 1.0f), q);
}
