# CPU (Swift) practices for MetalRenderer

Always measure release builds (`swift build -c release`). Debug Swift is 10–100× slower in hot loops and tells you
nothing.

## 1. The frame loop (`Renderer.draw`)

`draw` is an outline; each step is its own function, in this order:

| Step | Function | What it may touch |
|---|---|---|
| Size, targets, upscalers | `frameSize`, `renderTargets`, `prepareUpscalers` | allocates on a size change only |
| CPU work | `simulate`, `detailView`, `writeFrameData` | the scene, the slot's buffers |
| Plan | `planFrame` → `FramePlan` | reads settings, scene and last frame's flags once; allocates lazily made targets |
| Stages | `headStages`, `giStages`, `restirStages`, `svgfStages`, `fogStages`, … | read the plan only; fill `CompositeInputs` |
| Encoding | `encode`, `encodeOutput`, `commit` | `FramePasses` owns the command buffers and the open encoder |
| History | `finishFrame` | the only place that sets what the next frame reuses |

* **A new pass is a stage builder.** It takes the `FramePlan`, returns `[ComputeStage]` and joins a group in
  `FrameStages`. Add what it needs to know to the plan (`planFrame`); don't read `settings`-derived modes
  (`activeGIMode`, `activeDirectMode`) or "written last frame" flags inside it.
* **State for the next frame is set in `finishFrame`,** from the plan. A flag set while stages are being built is
  read by a later stage of the same frame as if it were last frame's.

* **Never wait on the GPU.**
  * `frameSemaphore` (3 slots, `Renderer.maxFramesInFlight`) is the only throttle.
  * `waitUntilCompleted` belongs to setup, acceleration-structure builds, scene swaps (which drain all slots first,
    `Renderer.install`) and benchmarks.
* **No allocations per frame.**
  * Don't create `MTLBuffer`/`MTLTexture` objects in `draw`. Size them once and recreate only when the size or scene
    changes.
  * Don't build arrays or dictionaries per frame. If you must, keep them as stored properties and use
    `removeAll(keepingCapacity: true)`.
  * Don't format `String`s per frame, except for the window title and labels at a low rate.
  * Closures that capture `self` per frame allocate. The completed handler is the one accepted exception. Keep it
    small and capture locals, not `self` state you then read.
* **Uploads:**
  * small, per-dispatch constants use `setBytes` (the `Uniforms` pattern);
  * arrays use the per-slot shared buffer, filled with `withUnsafeBytes { contents().copyMemory(...) }`
    (VirtualBLAS.swift `tables[slot]`);
  * single structs inside fixed arrays use `withUnsafeMutableBytes` + `storeBytes` (GPUTypes.swift:167).
* **The main thread is for UI.**
  * Panels refresh at 2 Hz; only the frame graph updates every frame.
  * Coalesce `DispatchQueue.main.async` hops to one per frame (the completed handler does exactly one).
  * Don't touch AppKit from render callbacks.
  * Don't hop through `Task`/`async` on the per-frame path: each hop costs scheduling and an allocation.

## 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise)

* **Use value types and `final class`.** Every class here is `final`; keep new ones `final` too. That gives static
  dispatch. Avoid protocols, existentials (`any P`) and generic code that isn't specialized inside a hot loop.
* **Remove bounds and CoW checks** on proven-hot loops with `withUnsafeBufferPointer` /
  `withUnsafeMutableBufferPointer` (BVH.swift and CustomRayTracer.swift do this). Keep the unsafe region small.
* **Reserve capacity.** `reserveCapacity` before append loops (BVH, MeshSimplifier, MeshClusterizer, Scene). Better
  still, preallocate with `Array(repeating:count:)` and write by index.
* **No dictionaries or sets in inner loops** when a dense index works. Map IDs to `0..<n` once, then use arrays.
  Hashing dominates otherwise.
* **SIMD:**
  * use `SIMD3<Float>` / `SIMD4<Float>` and `simd` functions (`min`, `max`, `dot`, `length`) for vector math;
  * `SIMD3<Float>` has a 16-byte stride, so for large arrays of positions consider SoA or packed `Float` triples;
  * keep AABB math in SIMD4 (as `BVHNode` does).
* **ARC:** reading a class reference inside a loop can retain and release. Hoist class properties into locals (`let
  nodes = self.nodes`) before the loop. Keep closures out of the hot path.
* **Algorithmic wins dwarf micro-optimizations.**
  * binned SAH (16–32 bins) instead of a full sweep;
  * a heap or priority queue for edge collapses;
  * precomputed adjacency;
  * spatial hashing for neighbour queries.

  Check the complexity before tuning constants.

## 3. Parallelism

* **`DispatchQueue.concurrentPerform`** is the project's pattern, used in BVH.swift:207, FogNoise.swift:40,
  MaterialTextures.swift:17, VirtualBLAS.swift:138, TextureStreamer.swift:311 and VirtualGeometryBuilder.swift:210.
  * Iterate over coarse units (meshes, groups, slices, textures) so each iteration does at least ~100 µs of work.
  * Chunk fine-grained work manually (`iterations: cores * 4`, then a range per iteration).
  * Each iteration writes to its own preallocated slot (`UnsafeMutableBufferPointer` captured before the call). No
    locks or shared appends inside.
  * Merge the results serially afterwards, or under a lock only for rare events.
* **Locks:** `NSLock` for rare state shared between the render thread and a worker (VirtualBLAS `busy`/`finished`,
  TextureStreamer). Hold a lock only to swap a pointer or an array, never while doing work.
* **The background build handoff pattern** (VirtualBLAS.swift ~120–145) is the template for any heavy per-change CPU
  work:
  1. The render thread starts a job on `worker` if none is running (`busy`).
  2. The job appends its results to `finished` under the lock.
  3. At the next frame, the render thread takes `finished` and installs the results.
  4. Replaced GPU resources go to `retired` with the current frame number and are released after
     `maxFramesInFlight` frames.

  Benchmarks run the job synchronously, which makes them deterministic (`METALRENDERER_VG_SYNC`).
* Scene loads and glTF imports use `Task` / background queues and swap in whole prepared scenes. Keep large builds out
  of the frame loop entirely.

## 4. CPU↔GPU data layout

* Every struct shared with MSL lives in `GPUTypes.swift` and must match `Shaders/Types.metal` byte for byte:
  * `SIMD3<Float>` ↔ `float3` is 16 bytes with 16-byte alignment;
  * `packed_float3` in MSL is 12 bytes, and Swift has no direct equivalent (use three `Float`s);
  * `Bool` sizes differ, so use `UInt32` flags (as `GPUFogParams` does).
* When adding or changing a shared struct, compare `MemoryLayout<T>.stride` with the MSL size, either with a debug
  `assert` or by reading the struct in a one-off kernel.
* Pack for the GPU's access pattern, not the CPU's convenience. Hot fields go together, and the 16-byte alignment of
  `float4` drives the layout.
* **Big per-frame uploads go through a staging array and one `copyMemory`**, not record by record into the buffer's
  `contents()`. Records written one at a time stay in the CPU's caches, and the GPU then reads them more slowly: with
  16384 moving lights (3.5 MB of instances, 1 MB of lights) direct writes cost the GPU 0.35 ms a frame; a large
  memcpy doesn't leave the data there. Keep the staging array between frames and rewrite only what changed
  (`Renderer.instanceStage` / `lightStage`, `Scene.writeInstanceData(into:all:)`).
* A struct shared with MSL gets a `precondition` on its stride in `validateGPULayouts` and a `static_assert(sizeof…)`
  next to its MSL definition.

## 5. Preprocessing and caches

* Anything that takes more than about a second per asset is cached on disk in `Assets/.metalrenderer-cache/`: the
  cluster-DAG pages and the texture mip chains.
* Key the cache by source identity plus a format/algorithm version. The example is VirtualGeometryBuilder.swift:351:
  `static let version`, and the file name is `<model>-<size>-<mtime>-v<version>.mgv`. Bump the version when the
  builder's output changes, or stale caches will hide the change (and its cost).
* To time a builder, delete its cache entries first, or you're timing a disk read.

## 6. CPU tools

* **The Debug window's orange line** is the CPU frame interval: the time between frame starts, including waiting on
  the display. If it sits above the blue GPU line, the CPU or vsync is the limit.
* **The benchmark table's `cpu` column** (and "encode" in the Debug window's stats line) is the CPU's own work per
  frame without those waits. Use it for before/after numbers of per-frame CPU changes.
* **Time Profiler:**
  ```bash
  xcrun xctrace record --template 'Time Profiler' --time-limit 15s --launch -- .build/release/MetalRenderer
  ```
  Open the `.trace` in Instruments. Invert the call tree and hide system libraries to find hot Swift frames.
* **Allocations** (`--template 'Allocations'`): look for steady growth or per-frame transient allocations in `draw`.
* **Builders:** time them in isolation with `ContinuousClock().measure { … }` around the call, in a release build,
  with the cache cleared.
