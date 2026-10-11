// ---------------------------------------------------------------------------------------------
// Our own denoising upscaler (NeuralUpscaler.swift; trained by Tools/neural, whose model.py is the reference for
// every kernel here): a recurrent U-Net at the render resolution, padded to a multiple of 2^(levels - 1), over the
// frame's noisy light and guides plus last frame's output and state, warped by the motion and folded into the render
// resolution. Tensors are half, planar: channel c of a W x H tensor starts at c * W * H. Weights keep PyTorch's
// [out][in][ky][kx]. The net's architecture (model.py's `arch`): v1 or v2 inputs (v2 adds the light in parts, the
// composite's FLAG_SPLIT_OUTPUT), a direct or a kernel head, a bilinear or bicubic warp.
// ---------------------------------------------------------------------------------------------

struct NeuralParams {
    uint4  size;       // x, y: this dispatch's tensor width, height; z, w: the frame's render width, height (unpadded)
    uint4  channels;   // x: input 0's (prepare: the guides), y: input 1's (concatenated after it), z: output's, w: NEURAL_* flags
    float4 frame;      // x: exposure, y, z: jitter (render pixels)
    uint4  shape;      // x: upscale factor, y: state channels (the output's + hidden), z, w: output width, height (unpadded)
};

constant uint NEURAL_RELU     = 1;   // conv: ReLU after the bias
constant uint NEURAL_UPSAMPLE = 2;   // conv: input 0 is at half this resolution (nearest 2x upsampling)
constant uint NEURAL_RESET    = 4;   // warp: no history (zeros)
constant uint NEURAL_BICUBIC  = 8;   // warp: bicubic instead of bilinear
constant uint NEURAL_GUIDES_V1 = 14; // prepare: v1's guides; 24 with the light in parts and the history validity

/// PyTorch's bicubic weights (cubic convolution, A = -0.75) for the taps at -1, 0, 1, 2 of a fraction t.
constant float NEURAL_CUBIC_A = -0.75f;
inline float neuralCubicNear(float x) { const float a = NEURAL_CUBIC_A; return ((a + 2.0f) * x - (a + 3.0f)) * x * x + 1.0f; }   // |x| <= 1
inline float neuralCubicFar(float x) { const float a = NEURAL_CUBIC_A; return ((a * x - 5.0f * a) * x + 8.0f * a) * x - 4.0f * a; }   // 1 < |x| < 2
inline float4 neuralCubic(float t) {
    return float4(neuralCubicFar(t + 1.0f), neuralCubicNear(t), neuralCubicNear(1.0f - t), neuralCubicFar(2.0f - t));
}

/// model.py's log light: log1p of the exposed light, negatives as 0.
inline float3 neuralLogLight(float3 l, float exposure) { return log(1.0f + max(l, 0.0f) * exposure); }

// Last frame's output and state (output resolution) moved to this frame: each output pixel reads last frame's at its
// position plus the motion of the render pixel under it (model.py's warp, grid_sample with border padding): bilinear
// with the position clamped to the edges, or bicubic with each of the 4x4 taps clamped.
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
    if (p.channels.w & NEURAL_BICUBIC) {
        float2 u = float2(q) + motion.read(r).xy * float(f), base = floor(u);
        float4 wx = neuralCubic(u.x - base.x), wy = neuralCubic(u.y - base.y);
        uint xs[4], ys[4];
        for (int k = 0; k < 4; k++) {
            xs[k] = uint(clamp(int(base.x) + k - 1, 0, int(w) - 1));
            ys[k] = uint(clamp(int(base.y) + k - 1, 0, int(h) - 1));
        }
        for (uint c = 0; c < p.shape.y; c++) {
            device const half* s = state + c * n;
            float v = 0.0f;
            for (int j = 0; j < 4; j++) {
                float row = 0.0f;
                for (int k = 0; k < 4; k++) row += float(s[ys[j] * w + xs[k]]) * wx[k];
                v += row * wy[j];
            }
            warped[c * n + i] = half(v);
        }
        return;
    }
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
// (f * x + j, f * y + i) of channel c). channels.x: the guides, 14 (v1) or 24 (v2: textures 5-7 are read too).
kernel void neuralPrepareKernel(constant NeuralParams&         p         [[buffer(0)]],
                                device const half*             warped    [[buffer(1)]],
                                device half*                   x         [[buffer(2)]],
                                texture2d<float, access::read> color     [[texture(0)]],
                                texture2d<float, access::read> albedo    [[texture(1)]],
                                texture2d<float, access::read> specular  [[texture(2)]],
                                texture2d<float, access::read> normal    [[texture(3)]],
                                texture2d<float, access::read> roughness [[texture(4)]],
                                texture2d<float, access::read> diffuse   [[texture(5)]],   // v2: light / albedo
                                texture2d<float, access::read> specularLight [[texture(6)]],   // v2: specular light / specular albedo
                                texture2d<float, access::read> extra     [[texture(7)]],   // v2: emission, fog; a = history validity
                                uint2 tid [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h, f = p.shape.x, g = p.channels.x;
    if (tid.x >= w || tid.y >= h) return;
    uint2 s = min(tid, p.size.zw - 1);
    float4 nd = normal.read(s);
    float v[26];
    float3 c = neuralLogLight(color.read(s).rgb, p.frame.x), a = albedo.read(s).rgb, sp = specular.read(s).rgb;
    v[0] = c.x; v[1] = c.y; v[2] = c.z;
    v[3] = a.x; v[4] = a.y; v[5] = a.z;
    v[6] = sp.x; v[7] = sp.y; v[8] = sp.z;
    v[9] = nd.x; v[10] = nd.y; v[11] = nd.z;
    v[12] = nd.w > 0.0f ? 1.0f / (1.0f + nd.w) : 0.0f;   // sky: 0
    v[13] = roughness.read(s).r;
    if (g > NEURAL_GUIDES_V1) {
        float3 d = neuralLogLight(diffuse.read(s).rgb, p.frame.x), sl = neuralLogLight(specularLight.read(s).rgb, p.frame.x);
        float4 e = extra.read(s);
        float3 el = neuralLogLight(e.rgb, p.frame.x);
        v[14] = d.x; v[15] = d.y; v[16] = d.z;
        v[17] = sl.x; v[18] = sl.y; v[19] = sl.z;
        v[20] = el.x; v[21] = el.y; v[22] = el.z;
        v[23] = e.a;
    }
    v[g] = p.frame.y; v[g + 1] = p.frame.z;
    uint i = tid.y * w + tid.x;
    for (uint k = 0; k < g + 2; k++) x[k * n + i] = half(v[k]);
    uint ow = w * f, on = n * f * f;
    for (uint ch = 0; ch < p.shape.y; ch++) {
        for (uint dy = 0; dy < f; dy++) {
            for (uint dx = 0; dx < f; dx++) {
                x[(g + 2 + ch * f * f + dy * f + dx) * n + i] = warped[ch * on + (tid.y * f + dy) * ow + tid.x * f + dx];
            }
        }
    }
}

// 3x3 convolution, zero padded, four output channels a thread (the last thread's past channels.z do nothing). Input
// 1's channels follow input 0's (the U-Net's skip connections); input 0 can be at half the resolution, read as if
// upsampled by repeating each pixel.
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
    uint4 oc = min(uint4(co, co + 1, co + 2, co + 3), p.channels.z - 1);   // past the last channel: the last again, not written
    float4 acc = float4(bias[oc.x], bias[oc.y], bias[oc.z], bias[oc.w]);
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
                uint wi = ci * 9 + k;
                acc += v * float4(weights[oc.x * stride + wi], weights[oc.y * stride + wi], weights[oc.z * stride + wi],
                                  weights[oc.w * stride + wi]);
            }
        }
    }
    if (p.channels.w & NEURAL_RELU) acc = max(acc, 0.0f);
    uint i = tid.y * w + tid.x;
    for (uint k = 0; k < 4 && co + k < p.channels.z; k++) out[(co + k) * n + i] = half(acc[k]);
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

// The kernel head (model.py's DenoisingUpscaler._kernel), per output pixel: softmax weights over the 3x3 render pixels
// around its own and the warped history, for each part of the light (diffuse, specular, extra: exposed linear light,
// the history in log light), and a blend weight that accumulates the surface's colours over the jittered frames. The
// light is albedo * diffuse + max(specular albedo, 1e-3) * specular + extra. Writes the state (log parts, the colours,
// the hidden channels) over last frame's and the linear light before exposure.
kernel void neuralKernelFinishKernel(constant NeuralParams&          p        [[buffer(0)]],
                                     device const half*              head     [[buffer(1)]],
                                     device const half*              warped   [[buffer(2)]],
                                     device half*                    state    [[buffer(3)]],
                                     texture2d<float, access::write> output   [[texture(0)]],
                                     texture2d<float, access::read>  albedo   [[texture(1)]],
                                     texture2d<float, access::read>  specular [[texture(2)]],
                                     texture2d<float, access::read>  diffuse  [[texture(3)]],
                                     texture2d<float, access::read>  specularLight [[texture(4)]],
                                     texture2d<float, access::read>  extra    [[texture(5)]],
                                     uint2 q [[thread_position_in_grid]])
{
    uint w = p.size.x, h = p.size.y, n = w * h, f = p.shape.x;
    if (q.x >= w || q.y >= h) return;
    uint rw = w / f, rn = n / (f * f);
    uint2 r = q / f;
    uint ri = r.y * rw + r.x, sub = (q.y % f) * f + q.x % f;
    device const half* cell = head + sub * rn + ri;   // channel c of this output pixel: cell[c * f * f * rn]
    uint step = f * f * rn;
    uint i = q.y * w + q.x;
    float e = p.frame.x;
    int2 last = int2(p.size.zw) - 1;
    float3 parts[3];
    for (uint k = 0; k < 3; k++) {
        float logits[10], top = -INFINITY;
        for (uint j = 0; j < 10; j++) { logits[j] = float(cell[(10 * k + j) * step]); top = max(top, logits[j]); }
        float sum = 0.0f;
        for (uint j = 0; j < 10; j++) { logits[j] = exp(logits[j] - top); sum += logits[j]; }
        float3 acc = float3(0.0f);
        for (int j = 0; j < 9; j++) {
            uint2 s = uint2(clamp(int2(r) + int2(j % 3 - 1, j / 3 - 1), int2(0), last));
            float3 l = k == 0 ? diffuse.read(s).rgb : k == 1 ? specularLight.read(s).rgb : extra.read(s).rgb;
            acc += logits[j] * max(l, 0.0f) * e;
        }
        float3 past = float3(warped[(3 * k) * n + i], warped[(3 * k + 1) * n + i], warped[(3 * k + 2) * n + i]);
        acc += logits[9] * max(exp(past) - 1.0f, 0.0f);
        parts[k] = acc / sum;
    }
    uint2 s = min(r, uint2(last));
    float beta = 1.0f / (1.0f + exp(-float(cell[30 * step])));
    float3 histAlbedo = float3(warped[9 * n + i], warped[10 * n + i], warped[11 * n + i]);
    float3 histSpecular = float3(warped[12 * n + i], warped[13 * n + i], warped[14 * n + i]);
    float3 a = max(beta * histAlbedo + (1.0f - beta) * albedo.read(s).rgb, 0.0f);   // the bicubic warp overshoots
    float3 sa = max(beta * histSpecular + (1.0f - beta) * specular.read(s).rgb, 0.0f);
    float3 light = a * parts[0] + max(sa, 1e-3f) * parts[1] + parts[2];
    float v[15] = { log(1.0f + parts[0].x), log(1.0f + parts[0].y), log(1.0f + parts[0].z),
                    log(1.0f + parts[1].x), log(1.0f + parts[1].y), log(1.0f + parts[1].z),
                    log(1.0f + parts[2].x), log(1.0f + parts[2].y), log(1.0f + parts[2].z),
                    a.x, a.y, a.z, sa.x, sa.y, sa.z };
    for (uint c = 0; c < 15; c++) state[c * n + i] = half(v[c]);
    for (uint c = 15; c < p.shape.y; c++) state[c * n + i] = half(precise::tanh(float(cell[(c + 16) * step])));
    if (q.x < p.shape.z && q.y < p.shape.w) output.write(float4(light / e, 1.0f), q);
}
