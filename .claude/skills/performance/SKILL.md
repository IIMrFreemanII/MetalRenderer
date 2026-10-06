---
name: performance
description: Write and optimize fast CPU (Swift) and GPU (Metal/MSL) code in MetalRenderer, and prove it with the project's benchmarks. Use when making something faster, investigating a slow pass, fps or ms regressions, bandwidth, occupancy, register pressure, threadgroup sizes, atomics, allocations or hot loops; when writing or reviewing a new compute kernel, per-frame encoding code or an offline builder; or when asked to profile, benchmark or A/B a change.
---

# Performance in MetalRenderer

Three rules hold everywhere. Don't optimize without a number: every change is measured before and after. Don't take a
speedup that costs image quality without a score. Don't trust a single run.

The renderer is GPU-bound almost everywhere. A frame is around 640×400 traced and upscaled 3× to 1920×1200, on Apple
silicon (the README's numbers are from an M1 Max, which has no ray-tracing hardware). The CPU matters for the frame loop
(encoding, uploads, the virtual-geometry cut, texture streaming) and for offline builders (mesh simplification,
clustering, cluster-DAG pages and their trees, distance fields, texture mips). Every ray goes through Metal's
acceleration structures and intersector: in software on M1/M2, in hardware from M3 on.

## The loop

1. **Baseline.** `swift build -c release`, then run a narrowed benchmark from the repo root (see
   [references/measuring.md](references/measuring.md)):
   ```bash
   METALRENDERER_BENCH=stress METALRENDERER_BENCH_ONLY="32 lights" .build/release/MetalRenderer
   ```
   Save the table to the scratchpad. Per-pass columns come from serialized frames. Confirm whole-frame cost with
   `METALRENDERER_BENCH_SPLIT=0`.
2. **Find the bound.** First find which pass is slow, then why. Run cheap experiments before reading the code:
   * Halve `METALRENDERER_GI=scale=…`. If the pass scales with pixels, it's per-pixel bound (bandwidth or ALU).
   * Sweep `METALRENDERER_TG="<kernel>=16x8"`. Big swings point to occupancy or register pressure, or to cache
     locality.
   * `METALRENDERER_RT_STATS=1` shows the triangle and box candidates Metal's traversal hands the ray queries, per
     ray (every triangle is non-opaque in those builds; Metal can't count its nodes). That's traversal cost as far as
     it can be seen; view 13 ("Traversal cost") shows it per pixel.
   * Compile a feature out (a macro or function constant, or `on=0`-style overrides). What's left is that feature's
     price.
   * Bandwidth-bound passes (temporal, à-trous, composite, upscaler) barely react to ALU changes. ALU-bound ones
     (trace, ReSTIR) barely react to texture format changes.
3. **Change one thing.** Use the checklists below and the reference files.
4. **A/B, alternating.** `.claude/skills/performance/scripts/ab.sh -n 3 -- <env A> -- <env B>` runs A, B, A, B and so
   on, then prints medians and the delta. For code against code, build a baseline worktree (see measuring.md).
5. **Check quality.** Run the matching quality mode with `METALRENDERER_BENCH_DIR`, then its `Tools/eval/*.py`
   scorer (the `offscreen` skill's `render.sh` does both the run and the PNG list). For changes that must not alter the image, use `python3 Tools/eval/pngdiff.py <runA> <runB>`.
6. **Record.** Report whole-frame ms on the named GPU with the exact env line, the way the README does. Write down
   what didn't help too ("What didn't help" sections). Update the README when a default changes.

Every run is offscreen (no window, no focus change); never launch the binary without `METALRENDERER_BENCH`.

**Noise:**
* Timings swing 0.1–0.4 ms between launches, and single-frame PSNR swings ±0.1–0.2 dB. Smaller deltas are noise
  unless they repeat across alternating rounds.
* Long modes heat the GPU and it throttles. Prefer short, narrowed runs over full sweeps.
* Never time a debug build. Never time with the Debug window's pass timings or RT_STATS on: both slow the frame.

## Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md))

* **Bytes first.** Per-pixel passes are bandwidth-bound at these resolutions.
  * Use the smallest format that holds the precision: `rgba16Float` is the norm here. Justify any new `rgba32*`.
  * Use `half` for filter math. Read exact texels with `.read`, not `sample`.
  * Don't round-trip a value through memory when the next pass could compute it.
* **Fuse before you add a pass.** Every pass writes and re-reads full-screen textures. If the new work reads the same
  inputs as an existing kernel, put it there.
* **Keep big kernels lean.**
  * traceKernel and the ReSTIR kernels are register-bound. Keep live state small.
  * Avoid dynamically indexed local arrays: they spill to memory.
  * Compile features out instead of branching on them at runtime. Copy the patterns: kernel variants (`flagOn` /
    `passOn` in Shaders/Types.metal with `Kernel.fixedFlags` / `fixedPassFlags` in Pipelines.swift), the `LIGHT_SPEC`
    function constant and the `RT_STATS` macro (`Pipelines.compile`).
* **Branch on uniforms, not on pixels.** Keep loop trip counts uniform across a simdgroup. Make one memory fetch serve
  one decision: the 64-byte two-child node of a cluster's tree (`BVHNode`, BVH.swift) tests both children with one
  load.
* **Reduce before atomics** where a pass is dominated by them: simdgroup (`simd_sum`) → threadgroup → one
  `atomic_fetch_add_explicit(…, memory_order_relaxed)` per group. (Measure: four atomics per probe in `rcSHKernel`
  turned out not to matter.)
* **Threadgroup tiles** with an apron for neighbourhood filters (shadowTemporalKernel, Shaders/Denoise.metal). Use as
  few barriers as possible, and stay well under 32 KB so several groups fit per core.
* **Tune 2D dispatch sizes** in `Renderer.threadgroupSizes`. Sweep with `METALRENDERER_TG`.
  The defaults are 8×8, trace 16×8 and atrous 16×16.
* **Do expensive signals at lower rates:** a lower resolution (render scale, quarter budget), less often
  (`METALRENDERER_TLAS` rebuild cadence, refit in between), or amortized over frames with temporal reuse.

## Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md))

* **The frame never waits on the GPU.**
  * Three frames are in flight (`Renderer.maxFramesInFlight`, `frameSemaphore`).
  * Anything the CPU writes and the GPU reads is per slot (`slot = frameIndex % maxFramesInFlight`).
  * `waitUntilCompleted` is for setup, acceleration-structure builds and benchmarks only.
* **No allocations in `draw`.**
  * No new `MTLBuffer` or `MTLTexture` objects; reuse them and resize on demand.
  * No growing arrays or dictionaries, and no `String` formatting.
  * Small constants go through `setBytes` (under 4 KB, the `Uniforms` pattern). Larger data goes into per-slot
    shared buffers with `copyMemory`.
* **One command buffer per frame** in normal mode. Extra encoders and command buffers, and fences between them,
  serialize the GPU. Splitting is for profiling only.
* **Completed handlers do almost nothing.** They signal the semaphore, read times and hop to main with a single
  `DispatchQueue.main.async`.
* **Heavy CPU work goes off the frame loop** on a background queue, with the result handed over at a frame boundary.
  Release replaced GPU resources only after `maxFramesInFlight` frames (VirtualBLAS.swift: `finished`, then `retired`).

## Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures)

* **`DispatchQueue.concurrentPerform`** over coarse chunks (per mesh, per group, per slice). Each worker writes to
  disjoint, preallocated slots. Never take a lock inside the loop.
* **Hot loops use structs and `final class`.** Use `withUnsafe(Mutable)BufferPointer`, `reserveCapacity` and SIMD
  types. Avoid existentials, closures and dictionaries in the loop, and avoid ARC traffic from class references.
* **Cache anything slow to disk** with a versioned key. Bump the version whenever the format or the algorithm changes
  (the `Assets/.metalrenderer-cache` pattern).

## Before declaring done

* An A/B with at least 2 alternating rounds, with the medians and delta stated.
* The quality scorer, or `pngdiff.py`, shows no regression beyond the noise, or the trade-off is stated explicitly.
* Swift↔MSL struct layouts still match (`GPUTypes.swift` ↔ `Shaders/Types.metal`) if you touched a shared struct.
* `graphify update .` (CLAUDE.md).
