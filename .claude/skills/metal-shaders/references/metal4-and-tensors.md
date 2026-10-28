# Metal 4 and MSL Tensors

Metal 4 (iOS/macOS/visionOS 26, MSL 4.0; MSL 4.1 shipped with the 27 releases in 2026) adds a parallel set of `MTL4*` host types and first-class tensor types in the shading language. The classic API keeps working; adopt Metal 4 incrementally. Exact signatures move between OS releases — when writing Metal 4 code, check names against the SDK headers / current Apple docs, and say so if you can't verify.

## In MetalRenderer

Metal 4 is the only frame path (macOS 26 and an M3 or later; `Metal4Frame` in
`Sources/MetalRenderer/Renderer/Metal4Backend.swift`), and kernel code never sees it. Stages encode against
`ComputePass`, and `Metal4Frame` turns that into Metal 4:

* one `MTL4ArgumentTable` serves every dispatch (bindings are captured at each dispatch); `setBuffer` / `setTexture`
  write GPU addresses and resource IDs into it;
* `setBytes` copies into the frame slot's constants buffer, 16-byte aligned, and binds that address (Metal 4 has no
  inline constants);
* one `MTLResidencySet` on the queue; `useResource(s)` / `useHeap` only keep a resource resident. The set drops what
  no frame has declared for 600 frames, so a resource a kernel reaches through a pointer or argument buffer is
  declared **every frame**. A missed one works for 600 frames, then faults; run with `METALRENDERER_RESIDENCY_LIFE=16
  METALRENDERER_SHOT_FRAMES=1000` to see it at once (README, "Graphics API");
* a command allocator per frame slot; barriers between stages that depend on each other (`memoryBarrier`, and
  stages marked to overlap set their own);
* pipelines from `MTL4Compiler` (`Pipelines`), libraries still compiled from source.

What stays on the Metal 3 queue (texture uploads and mips, per-mesh acceleration structures, refits, MetalFX) is
listed in the class's doc comment and the README ("What stays on the Metal 3 queue"). Tests drive the same stages
through a Metal 3 encoder (`Tests/MetalRendererTests/Support/Metal3Pass.swift`). No kernel here uses tensors yet: a
first one would need its library compiled at `-std=metal4.0` (the others stay at 3.2) and an M5-class GPU to gain
from the neural accelerators.

The Swift sketch in §3 type-checks and the tensor kernel in §4 compiles against the macOS 27.0 SDK (metal
32023.921, October 2026); signatures have moved between releases, so re-check against the SDK in use.

## Contents
1. What changes for shader authors
2. Metal 4 host-side model (summary)
3. Minimal Metal 4 compute dispatch (Swift sketch)
4. MSL tensors and TensorOps
5. When to use what for ML math

## 1. What changes for shader authors

- Shader source is mostly unchanged: kernels, vertex/fragment functions, argument buffers and attributes are the same. Compile with `-std=metal4.0` (or newer) only if you use new language features (tensors, C++17 features).
- Binding: Metal 4 replaces per-encoder `setBuffer/setTexture` with **argument tables** (`MTL4ArgumentTable`) that hold buffer GPU addresses and texture resource IDs at binding indices. The `[[buffer(n)]]`/`[[texture(n)]]` indices in the shader still refer to slots — now slots in the argument table.
- Residency is explicit: every resource a shader touches must be in a **residency set** (`MTLResidencySet`) attached to the queue or command buffer. Missing residency → undefined results/faults rather than an obvious error. This includes resources reached indirectly through argument buffers.
- Function constants and specialization are expressed through function descriptors (`MTL4LibraryFunctionDescriptor`, `MTL4SpecializedFunctionDescriptor`) and compiled via `MTL4Compiler`.
- Synchronization between passes uses barriers/fences you encode yourself (Metal 4 encoders don't track hazards automatically for you the way classic tracked resources did). When porting a shader pipeline, add the barrier between a dispatch that writes a buffer and the one that reads it.

## 2. Host-side model (summary)

| Classic | Metal 4 |
|---|---|
| `MTLCommandQueue`, `MTLCommandBuffer` | `MTL4CommandQueue`, `MTL4CommandBuffer` + `MTL4CommandAllocator` (you manage memory reuse per frame) |
| `device.makeComputePipelineState(function:)` | `MTL4Compiler` (`device.makeCompiler`) creates pipelines from `MTL4ComputePipelineDescriptor` + function descriptors; supports async compile and pipeline serialization |
| `setBuffer/setTexture` per encoder | `MTL4ArgumentTable` bound with `setArgumentTable` |
| Automatic residency for bound resources (`useResource` for indirect) | `MTLResidencySet` — mandatory |
| Separate blit / compute / acceleration-structure encoders | Unified `MTL4ComputeCommandEncoder` does compute, blit and AS builds |
| Implicit hazard tracking (tracked resources) | Explicit barriers (e.g. stage-to-stage barriers on encoders) |
| — | `MTL4MachineLearningCommandEncoder` runs exported ML packages (`MTLPackage`) inline in the command buffer |

## 3. Minimal Metal 4 compute dispatch (Swift sketch)

```swift
// One-time setup
let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
let fnDesc = MTL4LibraryFunctionDescriptor()
fnDesc.name = "saxpy"
fnDesc.library = device.makeDefaultLibrary()!
let pipeDesc = MTL4ComputePipelineDescriptor()
pipeDesc.computeFunctionDescriptor = fnDesc
let pso = try compiler.makeComputePipelineState(descriptor: pipeDesc)

let tableDesc = MTL4ArgumentTableDescriptor()
tableDesc.maxBufferBindCount = 4
let argTable = try device.makeArgumentTable(descriptor: tableDesc)

let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
residency.addAllocation(xBuf); residency.addAllocation(yBuf); residency.addAllocation(paramsBuf)
residency.commit()
let queue = device.makeMTL4CommandQueue()!
queue.addResidencySet(residency)
let allocator = device.makeCommandAllocator()!

// Per dispatch
let cmd = device.makeCommandBuffer()!            // MTL4CommandBuffer
cmd.beginCommandBuffer(allocator: allocator)
let enc = cmd.makeComputeCommandEncoder()!
enc.setComputePipelineState(pso)
argTable.setAddress(xBuf.gpuAddress, index: 0)
argTable.setAddress(yBuf.gpuAddress, index: 1)
argTable.setAddress(paramsBuf.gpuAddress, index: 2)   // no setBytes in Metal 4: put small constants in a buffer
enc.setArgumentTable(argTable)
enc.dispatchThreads(threadsPerGrid: MTLSize(width: n, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
enc.endEncoding()
cmd.endCommandBuffer()
queue.commit([cmd])
```
This type-checks against the macOS 27.0 SDK (`swiftc -typecheck`); it isn't a complete program (no error handling, no frame pacing). Key porting changes: no `setBytes` (use a ring buffer of small constant buffers), explicit residency, allocator reset only after the GPU finished with that frame's commands (use a shared event or feedback handler).

## 4. MSL tensors and TensorOps

MSL 4 adds `tensor` types (multi-dimensional views over device memory or inline storage) and the **Metal Performance Primitives** library, whose **TensorOps** provide `matmul2d`, convolution and reductions that run on the GPU's matrix hardware — including the neural accelerators in each GPU core on M5 / A19 Pro — without per-GPU code. Quantized element types (int8/int4 from the 26.x updates; fp8/fp4/int2 and per-block E8M0 scale planes in the 27 releases) are dequantized inside the op.

Typical structure of a TensorOps matmul kernel (compiles with `-std=metal4.0` against the macOS 27.0 SDK; the header `MetalPerformancePrimitives/MPPTensorOpsMatMul2d.h` documents the op, its supported type combinations and a faster no-bounds-check variant):

```metal
// check: -std=metal4.0
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp::tensor_ops;

kernel void matmulTensor(tensor<device half,  dextents<int32_t, 2>> A [[buffer(0)]],
                         tensor<device half,  dextents<int32_t, 2>> B [[buffer(1)]],
                         tensor<device float, dextents<int32_t, 2>> C [[buffer(2)]],
                         uint2 tgid [[threadgroup_position_in_grid]])
{
    // Describe a 64x32 output tile computed cooperatively by the whole threadgroup.
    // K = dynamic_extent: read from the tensors' extents.
    constexpr auto desc = matmul2d_descriptor(64, 32, static_cast<int>(dynamic_extent),
                                              /*transpose_left*/ false, /*transpose_right*/ false,
                                              /*relaxed_precision*/ false);
    matmul2d<desc, execution_simdgroups<4>> op;

    // Slice the tensors to this threadgroup's tile, then run.
    auto a = A.slice(0, tgid.y * 64);
    auto b = B.slice(tgid.x * 32, 0);
    auto c = C.slice(tgid.x * 32, tgid.y * 64);
    op.run(a, b, c);
}
```

Concepts to get right:
- **Tensor handles** are bound from host `MTLTensor` objects (`device.makeTensor(descriptor:)` with dimensions, strides, data type, usage); they carry their own extents, so kernels don't need separate size arguments.
- **Execution scope** (`execution_thread`, `execution_simdgroup`, `execution_simdgroups<N>`) says which threads cooperate on one op; every thread in that scope must call `run`.
- **Cooperative tensors** keep an op's output distributed across the participating threads' registers. Use them to fuse work (e.g. bias + activation, softmax with `reduce_rows`) before storing, and — on the 27 SDKs — to feed one matmul's output directly into the next as the left input after checking layout compatibility; otherwise round-trip through threadgroup memory.
- **Fused attention** (FlashAttention-style): Q·Kᵀ into a cooperative tensor per SIMD-group that owns whole rows, row-wise softmax with reductions, then multiply by V — one kernel, no intermediate matrix in device memory.
- In shaders (neural rendering), small MLPs (a few thousand parameters) can run inline per pixel with `execution_simdgroup` scope: `matmul2d` per layer, activations applied in place on the cooperative tensor.

## 5. When to use what for ML math

1. MLX / Core AI / Core ML / MPSGraph — standard models and ops; least code.
2. MPS kernels (`MPSMatrixMultiplication` etc.) — standard ops inside an existing Metal pipeline.
3. TensorOps in a custom kernel — custom fused ops, quantization formats, inline networks in render shaders; gets neural-accelerator speed portably.
4. Hand-written `simdgroup_matrix` code — when targeting pre-Metal-4 OS versions; see `compute-patterns.md` §6.
