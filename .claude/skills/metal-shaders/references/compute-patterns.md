# Compute Patterns

Copy-ready kernels with their dispatch assumptions. Each lists what the host must set up.

## Contents
1. Element-wise kernel (1D)
2. Image kernel with separable Gaussian blur
3. Parallel reduction (sum) with SIMD-groups
4. Prefix sum (scan) within a threadgroup
5. Histogram with atomics
6. Tiled matrix multiply (threadgroup memory) and simdgroup_matrix
7. Atomics reference
8. MLX custom Metal kernels
9. Host dispatch template (Swift)

## 1. Element-wise (1D)

```metal
kernel void saxpy(device const float* x  [[buffer(0)]],
                  device float*       y  [[buffer(1)]],
                  constant float&     a  [[buffer(2)]],
                  constant uint&      n  [[buffer(3)]],
                  uint i [[thread_position_in_grid]])
{
    if (i >= n) return;
    y[i] = fma(a, x[i], y[i]);
}
```
Host: `dispatchThreads(MTLSize(width: n, …), threadsPerThreadgroup: MTLSize(width: min(256, pso.maxTotalThreadsPerThreadgroup), …))`.
For bandwidth-bound kernels, process `float4` per thread (n/4 threads) when alignment allows.

## 2. Separable Gaussian blur (horizontal pass; vertical is symmetric)

```metal
constant int kRadius [[function_constant(0)]];   // e.g. 8

kernel void blurH(texture2d<half, access::sample> src [[texture(0)]],
                  texture2d<half, access::write>  dst [[texture(1)]],
                  constant float* weights [[buffer(0)]],   // kRadius+1 weights, weights[0] = center
                  uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 p = float2(gid) + 0.5;
    half4 acc = src.sample(s, p) * half(weights[0]);
    for (int i = 1; i <= kRadius; ++i) {
        half w = half(weights[i]);
        acc += (src.sample(s, p + float2(i, 0)) + src.sample(s, p - float2(i, 0))) * w;
    }
    dst.write(acc, gid);
}
```
Notes: `coord::pixel` uses texel-space coordinates (+0.5 = texel center). With `filter::linear` you can halve taps by sampling between texel pairs with combined weights. For very large radii, load a tile + apron into threadgroup memory instead: in MetalRenderer, `shadowTemporalKernel` (Shaders/Denoise.metal) is the model, with an 8×8 group, `half4` tiles and `max_total_threads_per_threadgroup(64)`.

## 3. Parallel reduction (sum)

Two-level: SIMD-group reduction in registers, then one value per SIMD-group through threadgroup memory. Writes one partial sum per threadgroup; run again (or atomically add) to finish.

```metal
kernel void reduceSum(device const float* in      [[buffer(0)]],
                      device float*       partial [[buffer(1)]],
                      constant uint&      n       [[buffer(2)]],
                      uint gid   [[thread_position_in_grid]],
                      uint lid   [[thread_index_in_threadgroup]],
                      uint tgid  [[threadgroup_position_in_grid]],
                      uint lane  [[thread_index_in_simdgroup]],
                      uint sgid  [[simdgroup_index_in_threadgroup]],
                      uint sgPerTG [[simdgroups_per_threadgroup]])
{
    threadgroup float sgSums[32];               // ≤ 1024 threads / 32 lanes

    float v = (gid < n) ? in[gid] : 0.0f;       // out-of-range threads contribute 0 but still participate
    v = simd_sum(v);
    if (lane == 0) sgSums[sgid] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (sgid == 0) {
        float s = (lane < sgPerTG) ? sgSums[lane] : 0.0f;
        s = simd_sum(s);
        if (lane == 0) partial[tgid] = s;
    }
}
```
Speed-up: have each thread first accumulate several elements in a strided loop (grid-stride) so fewer threadgroups are launched. Float sums are order-dependent; expect tiny differences vs CPU.

## 4. Threadgroup prefix sum (exclusive scan)

```metal
kernel void scanTG(device const uint* in  [[buffer(0)]],
                   device uint*       out [[buffer(1)]],
                   device uint*       blockSums [[buffer(2)]],
                   constant uint&     n   [[buffer(3)]],
                   uint gid  [[thread_position_in_grid]],
                   uint tgid [[threadgroup_position_in_grid]],
                   uint lane [[thread_index_in_simdgroup]],
                   uint sgid [[simdgroup_index_in_threadgroup]],
                   uint sgPerTG [[simdgroups_per_threadgroup]],
                   uint lid  [[thread_index_in_threadgroup]],
                   uint tgSize [[threads_per_threadgroup]])
{
    threadgroup uint sgTotals[32];
    uint v = (gid < n) ? in[gid] : 0;
    uint excl = simd_prefix_exclusive_sum(v);
    if (lane == 31 || lid == tgSize - 1) sgTotals[sgid] = excl + v;   // last active lane holds SIMD-group total
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (sgid == 0) {
        uint t = (lane < sgPerTG) ? sgTotals[lane] : 0;
        uint tExcl = simd_prefix_exclusive_sum(t);
        if (lane < sgPerTG) sgTotals[lane] = tExcl;
        if (lane == sgPerTG - 1) blockSums[tgid] = tExcl + t;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid < n) out[gid] = excl + sgTotals[sgid];
}
```
Full-array scan: scan blocks → scan `blockSums` → add block offsets in a third kernel. Assumes SIMD width 32 (true on Apple GPUs; check `threadExecutionWidth` if targeting AMD Macs).

## 5. Histogram with atomics

```metal
kernel void histogram256(texture2d<half, access::read> img [[texture(0)]],
                         device atomic_uint* bins [[buffer(0)]],      // 256 bins, zeroed by host
                         uint2 gid [[thread_position_in_grid]],
                         uint lid [[thread_index_in_threadgroup]],
                         uint2 tgSize2 [[threads_per_threadgroup]])
{
    threadgroup atomic_uint local[256];
    uint tgSize = tgSize2.x * tgSize2.y;
    for (uint i = lid; i < 256; i += tgSize) atomic_store_explicit(&local[i], 0, memory_order_relaxed);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (gid.x < img.get_width() && gid.y < img.get_height()) {
        half3 c = img.read(gid).rgb;
        uint luma = uint(saturate(dot(c, half3(0.2126h, 0.7152h, 0.0722h))) * 255.0h);
        atomic_fetch_add_explicit(&local[luma], 1, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = lid; i < 256; i += tgSize) {
        uint c = atomic_load_explicit(&local[i], memory_order_relaxed);
        if (c) atomic_fetch_add_explicit(&bins[i], c, memory_order_relaxed);
    }
}
```
Privatizing into threadgroup memory first cuts global atomic contention by orders of magnitude. Note there is no early `return` before the barriers.

## 6. Matrix multiply

### Tiled with threadgroup memory (portable)

```metal
#define TILE 16
kernel void matmulTiled(device const float* A [[buffer(0)]],   // M x K, row-major
                        device const float* B [[buffer(1)]],   // K x N
                        device float*       C [[buffer(2)]],   // M x N
                        constant uint3&     dims [[buffer(3)]],// (M, N, K)
                        uint2 gid [[thread_position_in_grid]], // x = col, y = row
                        uint2 lid [[thread_position_in_threadgroup]])
{
    threadgroup float As[TILE][TILE];
    threadgroup float Bs[TILE][TILE];
    uint M = dims.x, N = dims.y, K = dims.z;
    uint row = gid.y, col = gid.x;
    float acc = 0.0f;

    for (uint t = 0; t < K; t += TILE) {
        As[lid.y][lid.x] = (row < M && t + lid.x < K) ? A[row * K + t + lid.x] : 0.0f;
        Bs[lid.y][lid.x] = (col < N && t + lid.y < K) ? B[(t + lid.y) * N + col] : 0.0f;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint k = 0; k < TILE; ++k) acc = fma(As[lid.y][k], Bs[k][lid.x], acc);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row < M && col < N) C[row * N + col] = acc;
}
```
Host: threadgroup size exactly 16×16; dispatch `dispatchThreadgroups(ceil(N/16), ceil(M/16))` (or `dispatchThreads(N, M)` — partial threadgroups still work because loads are guarded and all threads hit the barriers).

### simdgroup_matrix (MSL 2.3+, Apple7+/M1+) — much faster

```metal
#include <metal_simdgroup_matrix>
// Each SIMD-group computes one 8x8 tile of C. Assumes M, N, K multiples of 8 (pad otherwise).
kernel void matmulSimd(device const float* A [[buffer(0)]],
                       device const float* B [[buffer(1)]],
                       device float*       C [[buffer(2)]],
                       constant uint3&     dims [[buffer(3)]],
                       uint2 tile [[threadgroup_position_in_grid]])   // one SIMD-group (32 threads) per threadgroup
{
    uint M = dims.x, N = dims.y, K = dims.z;
    uint row0 = tile.y * 8, col0 = tile.x * 8;
    if (row0 >= M || col0 >= N) return;           // uniform across the SIMD-group
    simdgroup_float8x8 acc = simdgroup_float8x8(0);
    simdgroup_float8x8 a, b;
    for (uint k = 0; k < K; k += 8) {
        simdgroup_load(a, A + row0 * K + k, K);
        simdgroup_load(b, B + k * N + col0, N);
        simdgroup_multiply_accumulate(acc, a, b, acc);
    }
    simdgroup_store(acc, C + row0 * N + col0, N);
}
```
Production kernels give each SIMD-group several 8×8 tiles (e.g. 32×32 per threadgroup of 4 SIMD-groups) and stage through threadgroup memory. On Metal 4 / M5+, prefer TensorOps `matmul2d` (see `metal4-and-tensors.md`) — it uses the GPU neural accelerators automatically. For standard sizes, MPS / MPSGraph / MLX are usually faster than a hand-rolled kernel.

## 7. Atomics reference

- Types: `atomic_int`, `atomic_uint`, `atomic_bool`; `atomic_float` on device memory (MSL 3.0+); 64-bit `atomic_ulong` min/max on supported GPUs.
- Ops: `atomic_load/store/exchange/compare_exchange_weak/fetch_add/fetch_sub/fetch_min/fetch_max/fetch_and/fetch_or/fetch_xor` with `_explicit` suffix.
- Memory order: only `memory_order_relaxed` is generally supported — atomics give atomicity, not ordering. Use barriers/fences for ordering within a threadgroup; across threadgroups, split into separate dispatches.
- Global atomics are a contention bottleneck: privatize per threadgroup first; aggregate within the SIMD-group (`simd_sum` + one atomic per SIMD-group) when all lanes add to the same address.

## 8. MLX custom Metal kernels

`mx.fast.metal_kernel` takes only the **body** of the kernel; MLX generates the signature from `input_names`/`output_names`.

```python
import mlx.core as mx

source = """
    uint elem = thread_position_in_grid.x;
    if (elem >= inp_shape[0]) return;   // MLX passes inp_shape automatically because the body references it
    out[elem] = metal::exp(inp[elem]);
"""
kernel = mx.fast.metal_kernel(name="myexp", input_names=["inp"], output_names=["out"], source=source)
a = mx.random.normal((4096,))
out = kernel(inputs=[a], grid=(a.size, 1, 1), threadgroup=(256, 1, 1),
             output_shapes=[a.shape], output_dtypes=[a.dtype])[0]
```
- `grid` is total threads (like `dispatchThreads`), not threadgroups.
- Attributes like `thread_position_in_grid` are available by name in the body.
- Templates: `template=[("T", mx.float32)]`; use `header=` for helper functions.
- Check the installed MLX version's docs for exact parameter names — the API has evolved.

## 9. Host dispatch template (Swift)

In MetalRenderer, a kernel is a `Kernel` case and a stage of the frame instead:

```swift
ComputeStage(pass: "saxpy") { [self] enc in            // enc: ComputePass (Metal 4 in the app, Metal 3 in tests)
    bind(enc, .saxpy, uniforms)                         // pipeline (or its variant) + Uniforms at buffer 0
    enc.setBuffer(xBuf, offset: 0, index: 1)
    enc.setBuffer(yBuf, offset: 0, index: 2)
    var params = SIMD4<Float>(a, Float(count), 0, 0)   // 16-byte groups, as the shared structs are
    enc.setBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 3)
    enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
}
```
2D kernels use `dispatch(enc, .kernel, width:height:)`, which takes the group from `Renderer.threadgroupSizes`.
Outside the engine:

```swift
let library = device.makeDefaultLibrary()!
let fn = library.makeFunction(name: "saxpy")!
let pso = try device.makeComputePipelineState(function: fn)   // once, at init

let cmd = queue.makeCommandBuffer()!
let enc = cmd.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
enc.setBuffer(xBuf, offset: 0, index: 0)
enc.setBuffer(yBuf, offset: 0, index: 1)
var a: Float = 2, n = UInt32(count)
enc.setBytes(&a, length: MemoryLayout<Float>.size, index: 2)
enc.setBytes(&n, length: MemoryLayout<UInt32>.size, index: 3)
let tg = MTLSize(width: min(256, pso.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: tg)
enc.endEncoding()
cmd.commit()
cmd.waitUntilCompleted()        // only for tools/tests; in apps use addCompletedHandler
```
