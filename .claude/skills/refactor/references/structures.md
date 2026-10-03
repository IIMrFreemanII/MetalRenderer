# Where new code belongs

Each structure below exists so that one kind of addition is one line, one case or one function. A feature written
in a hurry often goes around them. For each: where it lives, how a feature plugs in, and the signs it didn't.

Line numbers drift; find the names with `grep -n`. The frame loop and the pipeline set are described in more detail
in the `performance` skill ([cpu-swift.md](../../performance/references/cpu-swift.md) §1,
[gpu-metal.md](../../performance/references/gpu-metal.md) §8).

## Settings: `SettingsTable.swift`

* **What it is.** Every setting once, in `SettingsTable.sections`: its key path into `RenderSettings`
  (Settings.swift), its `METALRENDERER_*` name and its panel row. `SettingsEnv` reads and writes the variables from
  the table, `SettingsPanel` builds its rows from it.
* **Plugging in.** A field in `RenderSettings` and one line in a section: `S.slider(…)`, `S.check(…)` or
  `S.popup(…)`, with `.env(…)`, and `.when { }` / `.enabled( )` / `.available { }` for when it shows, is enabled and
  can be chosen. A row that spans several settings is an `S.custom` case, built by `SettingsPanel.customRow`.
* **Signs it was bypassed.** A new parser for a `key=value` list; a control or an action method added to
  `SettingsPanel` by hand; a setting missing from Copy as Env; a new `S.custom` for a row that one spec could
  describe.
* **Guard.** `SettingsTableTests`: every setting round-trips through Copy as Env, names are unique.

Two kinds of `ProcessInfo.processInfo.environment[…]` reads are the accepted pattern, not a bypass:
* A single-value variable that picks a default has a `static let initial` on its type (`RayTracerKind.initial`,
  `RenderAPI.initial` in Settings.swift), next to its `.env(…)` line in the table. Benchmarks rely on it.
* Run controls are not settings (`METALRENDERER_BENCH*`, `_CAPS`, `_TG`, `_RT_STATS`, `_DUMP_SETTINGS`). They are
  read where they are used.

## Benchmark modes: `Benchmark+Modes.swift`

* **What it is.** One function per mode returning `[Config]`, registered by name in `Benchmark.modes`. A `Config`
  (Benchmark.swift) is real `RenderSettings` plus how the run goes.
* **Plugging in.** A function and its entry in `modes`. Settings are built from a base with the modifiers:
  `named`, `with { }`, `view`, `fog { }`, `sky { }`, `direct`, `from`, `cameraMove`, `still`, `reference`, `moving`.
  Shared shapes are helpers (`scored` builds the static / moving / camera trio).
* **Signs it was bypassed.** `Config(` literals that repeat each other with one field changed; a mode that reads
  the environment itself for something `resolvedSettings()` already applies; a setting the renderer treats specially
  by its name.
* **Guard.** `BenchmarkModesTests`: every mode builds named settings; the modifiers; the env overrides.

## The frame: `Renderer.swift`

* **What it is.** `draw` is an outline. `planFrame` resolves every mode and switch once into a `FramePlan`. One
  function per stage group (`headStages`, `giStages`, `restirStages`, `svgfStages`, `fogStages`, …) builds
  `[ComputeStage]` from the plan into `FrameStages`. `encodeOutput` and `commit` finish the frame. `finishFrame` sets
  what the next frame reuses.
* **Plugging in.** A new pass is a stage builder that takes the plan. What it needs to know becomes a `FramePlan`
  field set in `planFrame`. What it leaves for the next frame is set in `finishFrame`.
* **Signs it was bypassed.** A stage builder that reads `settings`, the scene or a "written last frame" flag; the
  same condition spelled out in two builders (it is a plan field); history state assigned while stages are built;
  `draw` growing branches; a lazily made texture allocated inside a builder.
* **Guard.** None in the tests: identical images are the check (see [proving.md](proving.md)).

## Pipelines: `Pipelines.swift`

* **What it is.** `Kernel` has a case per compute function (`trace` ↔ `traceKernel`). `Pipelines` is the whole set
  as one value, compiled in the background for one tracer and one set of light types and swapped in between frames.
* **Plugging in.** One `Kernel` case named after the MSL function. Kernels that exist only for the custom tracer go
  after `rtPrep`. A compile-time variant is a macro set in `Pipelines.compile` or a function constant set where
  `Pipelines.init` makes each pipeline.
* **Signs it was bypassed.** `makeComputePipelineState` or `makeLibrary` anywhere else; a pipeline stored as its own
  property; a compile on the main thread or in the frame loop.

## Capabilities: `Capabilities.swift`

* **What it is.** What the GPU and the system can do, asked once at launch. `RenderSettings.missing(in:)` names what
  a setting needs, `clamped(to:)` falls back, the table's `.available { }` greys the option out, and
  `Benchmark.supported` skips the settings.
* **Plugging in.** A flag in `Capabilities` (with its `METALRENDERER_CAPS` key). When a setting can ask for it, also
  a clause in `missing` and in `clamped` and `.available` on the popup. A flag that only informs
  (`hardwareRayTracing` changes a title) needs none.
* **Signs it was bypassed.** `#available`, `supportsFamily` or `supportsDevice` outside `Capabilities.init`, beyond
  what the compiler demands at a call to a newer API; a feature that fails at use instead of falling back at launch.
* **Guard.** `CapabilitiesTests`: each missing capability falls back; the benchmark skips what can't run.

## Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`

* **What it is.** Stages encode through the `ComputePass` protocol and a frame through `FrameEncoder`, implemented
  by `Metal3Frame` and `Metal4Frame`.
* **Plugging in.** A new pass binds and dispatches through `ComputePass` only, so both back ends get it. Something
  one API can't do yet is said in one place, with the reason and the OS version (as for mipmaps and the denoising
  scaler under Metal 4).
* **Signs it was bypassed.** `MTLComputeCommandEncoder` in a stage builder; `api == .metal4` checks scattered over
  the stages; a feature that renders under one API and silently does nothing under the other.
* **Guard.** None that runs by itself. For a refactor, `same.sh <mode> -- METALRENDERER_API=metal4` shows Metal 4
  still draws what it drew. Metal 3 against Metal 4 is the `api` mode run once per API and `pngdiff.py` between the
  two folders (the mode's comment in Benchmark+Modes.swift).

## Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders.metal`

* **What it is.** Each struct both sides read has a `precondition(MemoryLayout<…>.stride == N)` in
  `validateGPULayouts` and a `static_assert(sizeof(…) == N, …)` in the shader that names its Swift twin.
* **Signs it was bypassed.** A new shared struct with neither; fields appended on one side; a
  `// xyz = …, w = …` comment that no longer matches the packing.

## Things that are not structures yet

When three features have each added the same kind of thing by hand, that is the next structure. The pass that
builds it adds its section here, with the test that guards it.
