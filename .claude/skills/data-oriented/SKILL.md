---
name: data-oriented
description: Design and build a new MetalRenderer feature the data-oriented way - decide which parts run every frame over many things (crowds, particles, physics, instances, lights, plants, culling, procedural or simulation work) and keep those in the fast subset of Swift (structs in flat arrays, no ARC, existentials, closures, strings, dictionaries or allocations in the loop, work in parts on every core or on the GPU), while one-off, event-driven and UI code stays plain Swift; then prove it with a profile and hotcalls.py. Use when planning or writing any new feature, system, scene element, simulation or gameplay mechanic, when adding a per-frame loop or a new kind of thing a scene has many of, or when choosing data layout, even if performance isn't mentioned. For speeding up existing code use the performance skill; for the pass after a feature, the refactor skill.
---

# Features, data first

Most of a frame is GPU work (default scenes: 0.2–1.4 ms of CPU against 4–10 ms of GPU on an M4 Max). A feature keeps it
that way when the part of it that runs **every frame over many things** is written in a restricted, fast subset of
Swift, and everything else is ordinary Swift. The subset is the Burst / DOTS idea: structs in flat arrays, no
reference counting, no dynamic dispatch, no allocation. Swift compiles it to code as fast as C. The rules below say
what it bans and what to use instead, with this project's own examples. The build checks it
(`Tools/perf/hotcalls.py`).

Three rules:
* **Decide where each part lives before writing it** (step 1). Most of a feature is not hot.
* **Write it plainly first, profile it, and port only what the profile shows.** Prototyping a mechanic is faster in plain
  Swift; the hot part is usually one loop.
* **A hot loop is proven twice:** by a number (the `cpu` column, a profile) and by the binary (`hotcalls.py`).

## 1. Sort the feature's parts

| Runs | Example | Write it as |
|---|---|---|
| Every frame, over hundreds or more | walkers, particles, moving instances, lights, plant descriptors, physics bodies | **The fast subset** (section 2), in parts on every core or on the GPU (section 4) |
| Every frame, a few times | the frame plan, a stage builder, a camera, one encoder's bindings | Plain Swift with no allocation per frame (performance skill, `references/cpu-swift.md` §1) |
| When something changes | a cut, a rebuild, a bake, a scene swap | A background job handed over at a frame boundary (the VirtualBLAS pattern, cpu-swift.md §3) |
| Once, or offline | builders, loaders, caches | Fast loops where the profile says so; cache the result on disk (cpu-swift.md §5) |
| On events, in the UI | editors, panels, menus, saving, gameplay rules that fire rarely | **Plain Swift.** Classes, protocols, closures, strings and dictionaries are fine. |

Write down which row each part of the feature is in before coding. A part in the first row gets a data layout
(section 3) before it gets an algorithm.

## 2. The fast subset: what it bans, what to use

| Not in a hot loop | Why | Instead (where the project does it) |
|---|---|---|
| Classes as elements, references between elements | retain/release per access | Structs in arrays, linked by **index** (`Crowd.Walker.instance`, `Scene.Instance.mesh`) |
| `any P`, protocols with several conformers | dynamic dispatch, no inlining | An enum with associated values, a generic that specialises, or one array and one loop per kind (`Scene.LightMotion` sorts lights into `animated` / `scaledLights` once) |
| Closures called per element | indirect call, captured context retained | Data: an enum of motions, parameters in the element. `Scene.Instance.animation` is the one accepted closure: called once per animated instance, never in the record loops |
| `String`, `[String: …]` | hashing, allocation, ARC | Integer IDs and dense indices; names stay outside the loop (`Scene.ObjectTag`) |
| `Dictionary`, `Set` in the loop | hashing dominates | Map IDs to `0..<n` once, then arrays |
| `map` / `filter` / `+` / appends building arrays per frame | an allocation each | Stored arrays reused with `removeAll(keepingCapacity: true)`, written by index |
| `self.array[i].field` on a class's array | an exclusivity check per access, and possibly a copy of the whole element | `array.withUnsafe(Mutable)BufferPointer { a in … a[i].field … }` around the loop; hoist other properties into `let`s first (`Scene.writeInstanceData`) |
| A large struct read whole (`let x = array[i]`) | copies every field | Read the fields you need through the buffer (`inst[i].transform`) |
| Metal / Objective-C objects asked per element (`structure.gpuResourceID`, `[MTLAccelerationStructure]` concatenated into `[MTLResource]`) | a message send or a protocol check per element | Cache the IDs and the resource lists once, rebuild them when the objects change (`SceneBuffers.primitiveIDs`, `PlantTracing.resources(slot:)`) |
| Spawning, destroying or adding to the arrays mid-loop | invalidates indices, needs locks | Collect commands into a buffer, apply them between frames (`Scene.moveInstances` + `takeInstanceEdits`, VirtualBLAS `finished`) |
| Variable-length data per element | an array per element | Index ranges into one shared array (PlantTracing's `partBase` / `partCount` into its `parts` buffer) |
| Locks, `Task` / `async` hops | contention, scheduling, allocation | Disjoint writes in parts (section 4); hand results over at a frame boundary |

The patterns, as code from this repo: [references/patterns.md](references/patterns.md).

## 3. Data layout

* **Hot apart from cold.** A per-frame loop touches few fields of many elements. Keep those fields in the element (or
  in their own array), and keep names, editor state and closures elsewhere. `Scene.Instance` (~290 bytes, three
  matrices) is read through its buffer for that reason. A new kind of thing with many instances should start small.
* **Structure of arrays** when a loop reads one or two fields of tens of thousands of elements (positions only, say).
  `SIMD3<Float>` has a 16-byte stride: for large position arrays use `SIMD4` or packed floats.
* **What the GPU reads** is a struct in `GPUTypes.swift` that matches `Shaders/Types.metal` byte for byte, with a stride
  `precondition` in `validateGPULayouts` and a `static_assert` in MSL (cpu-swift.md §4). Lay it out for the GPU's
  access, not the CPU's.
* **Write what changed, not everything.** The `animated` lists, `changingLights`, dirty ranges and generation counters
  (cpu-swift.md §1) keep per-frame work proportional to what moves.

## 4. Where the work runs

* **Thousands or more per frame: on the GPU** when the result is only drawn or traced (crowd skinning in
  `CrowdSkinner`, particles in `ParticlesGPU`, physics from `PhysicsSettings.gpuFrom` bodies). A CPU path stays as the
  small-scene fallback.
* **On the CPU, in parts on every core:** `SceneBuffers.inParts(count) { range in … }` (16384 per part) or
  `DispatchQueue.concurrentPerform` over chunks. Each part writes only its own elements (each walker owns its instance),
  through a buffer pointer captured before the call. No locks, no shared appends.
* **Off the frame loop** for anything that takes more than a frame's slack: the background-job handoff (cpu-swift.md §3).

## 5. Prove it

1. **Profile the feature's benchmark** (add a setting to `Benchmark+Modes.swift` with many of the new things, e.g. the
   crowd's 131072 characters):
   ```bash
   .claude/skills/data-oriented/scripts/profile.sh <mode> "<setting>"
   ```
   It records Time Profiler offscreen, keeps only the frames' samples (not the load), and prints the heaviest functions
   and runtime calls (`swift_beginAccess`, `swift_retain`, `objc_msgSend`, `_platform_memmove` …) with their callers.
   `--callers <symbol>` on its `profile.py` shows who calls one.
2. **A/B the `cpu` column** against a baseline build, 3 alternating rounds (performance skill:
   `.claude/skills/performance/scripts/ab.sh -n 3 -c "cpu,GPU total" --bin-a <baseline> -- … -- …`), then the whole
   frame with `METALRENDERER_BENCH_SPLIT=0`. Run it on both APIs (`METALRENDERER_API=metal3` / `metal4`).
3. **Lock the loop in.** Once a hot loop is clean, add its demangled name to `Tools/perf/hot-functions.txt` and run
   ```bash
   Tools/release.sh && python3 Tools/perf/hotcalls.py
   ```
   It fails if a listed function calls the runtime (retain/release, allocation, exclusivity or uniqueness checks,
   dynamic casts, Objective-C messages, generic metadata, lazy globals) or a function of another of the package's
   modules (nothing is inlined across modules: a per-element helper from another module is `@inlinable package`), or
   if a name no longer matches. Names are `swift-demangle --simplified` ones:
   find yours with `python3 Tools/perf/hotcalls.py -v` on a broad pattern, or in the profile's output. A closure the
   optimiser inlines has no body to check: list the function it was inlined into only if that one is clean too, or
   give the loop its own function.
4. **Images and tests:** the offscreen skill's `render.sh` before and after with `Tools/eval/pngdiff.py` (within the
   run-to-run noise of a baseline rendered twice), and the `tests` skill's `related.sh`.

## Before calling the feature done

* Every part of it sits in a row of the table in step 1, and the hot rows follow section 2.
* The feature's benchmark setting exists, and its `cpu` and whole-frame numbers are stated (README, the way the crowd's
  are).
* Its hot loops are in `Tools/perf/hot-functions.txt` and `hotcalls.py` passes.
* Images unchanged where the feature is off; related tests green; `graphify update .` (CLAUDE.md).
