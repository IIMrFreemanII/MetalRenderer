---
name: tests
description: Run MetalRenderer's unit tests the fast way - only the suites that cover the files a change touched, never the whole suite while developing. Use whenever you would run `swift test`, check or verify that a change still passes, after editing Swift or Metal sources, before a commit, or when a skill (refactor, performance) says to run the tests.
---

# Related tests only

The suite has about a hundred XCTest tests in 30 suites (`Tests/MetalRendererTests`). A full `swift test` takes about 40 s,
mostly in `KernelVariantsTests`, which compiles the kernel variants on the GPU. Running it after every step slows
development down, so run only the suites that cover what you changed.

## Rules

* **Never run a bare `swift test` while developing.** Run the related suites. Run the full suite only when the user
  asks for it.
* A change no suite covers (the renderer, cascades, denoiser, lighting shaders, UI) is proven with images, through
  the `offscreen` skill. Running the full suite doesn't prove it.
* Say which suites ran, and which changed files no suite covers.
* Run anything longer than about 30 s with `run_in_background`, then wait for the notification.

## Run them: `scripts/related.sh`

```bash
.claude/skills/tests/scripts/related.sh
```
* It reads the files changed against `HEAD` (uncommitted and untracked), maps them to suites and runs
  `swift test --filter '<A>|<B>'`.
* `--base <rev>` takes the changes since a revision instead, for example `--base main` for a whole branch.
* `--dry-run` prints the suites and the uncovered files and runs nothing.
* `related.sh CityTests BuildingTests` runs the suites you name and skips the map.

By hand, with the same filter:
```bash
swift test --filter 'CityTests|BuildingTests'
```
For one test, use `--filter CityTests/testThePlanIsSeeded`.

## Map

| Changed | Suites |
|---|---|
| `Settings*.swift` | SettingsTableTests, BenchmarkModesTests |
| `Benchmark*.swift` | BenchmarkModesTests, CapabilitiesTests |
| `Capabilities`, `Upscaler`, `Metal4Backend` | CapabilitiesTests |
| `ShaderSource`, `Pipelines`, `GPUTypes`, `Shaders.metal`, any `Shaders/*.metal` | ShaderSourceTests, KernelVariantsTests |
| `Shaders/Intersect.metal` (the ray queries) | ShaderSourceTests, KernelVariantsTests, PlantTracingTests |
| `BVH.swift` (the SAH builder over boxes, the clusters' trees) | BVHTests, CacheTests |
| `CacheFile`, `SectionFile`, `BlueNoise` | CacheTests |
| `Building*.swift`, `MeshBuilder` | BuildingTests, CityTests |
| `CityPlan`, `Scene+City` | CityTests, BuildingTests |
| `Scene+Stress` | StressSceneTests |
| `Crowd*.swift`, `SkinnedCharacter`, `Scene+Crowd`, `Shaders/Crowd.metal` | CrowdTests, FBXTests (`SkinnedCharacter`: + MuscleTests, the rig's poses) |
| `FBXReader` | FBXTests |
| `Foliage*.swift`, `Scene+Forest` | FoliageTests, ForestTests, FoliageRuntimeTests (all three in `FoliageTests.swift`) |
| `PlantTracing`, `Shaders/Foliage.metal` (the plants' variants, the wind) | PlantTracingTests, FoliageTests, ForestTests, FoliageRuntimeTests (the shader: + the shader pair) |
| `VoxelGrids`, `VoxelLOD` | FoliageRuntimeTests, SceneBuffersTests |
| `SDF*.swift`, `Scene+Shapes`, `Shaders/SDF.metal` | SDFTests, SceneBuffersTests, PhysicsTests (the shader: SDFTests + PhysicsTests + the shader pair) |
| `Physics*.swift`, `Scene+Physics`, `Scene+Ragdolls`, `Scene+Hair`, `Scene+Soft`, `Scene+Muscles`, `Shaders/Physics.metal` | PhysicsTests, RagdollTests, HairTests, SoftBodyTests, MuscleTests (the shader: + the shader pair) |
| `MuscleAtlas`, `SkeletonAtlas` | MuscleTests (the écorché and its skeleton) |
| `HairBSDF.swift`, `Shaders/Hair.metal` | HairTests (the shader: + the shader pair) |
| `GLTFLoader` | GLTFLoaderTests |
| `ProceduralTextures`, `MaterialTextures` | ProceduralTextureTests |
| `Scene.swift`, `SceneBuffers` | SceneBuffersTests |
| `LightTree.swift` | LightTreeTests |
| `RasterScene.swift` | RasterSceneTests |
| `VSM.swift` | VSMTests |
| `MeshSDFBuilder.swift`, `LumenScene.swift` | MeshSDFBuilderTests |
| `LumenGlobalSDF.swift` | GlobalSDFTests |
| `TextureStreamer` | TextureStreamerTests |
| `World*.swift`, `Scene+World`, `Terrain` | WorldTests, SceneBuffersTests |
| `Showcase.swift`, `Scene+Showcase` | ShowcaseTests |
| `VirtualGeometryBuilder` (its cache file) | CacheTests, VGStreamerTests |
| `VGStreamer`, `VirtualGeometry`, `RasterClusters` (streaming, the DAG's group records) | VGStreamerTests, VGCutTests |
| `VirtualTracing` (virtual geometry in Metal's structures) | VGCutTests, VGStreamerTests (+ prove with images: no suite traces it) |
| `TraceScene`, `Renderer` | none: prove with images (the offscreen skill) |
| `VirtualBLAS` (its cut, the reference), `Shaders/RasterClusters.metal`, `Shaders/Raster.metal`, `Shaders/VirtualGeometry.metal` | VGCutTests (the shaders: plus the shader pair) |
| `Tests/MetalRendererTests/XTests.swift` | XTests |
| `Package.swift`, a shared test helper | all suites: the one case where the full run is right |

What each suite guards is listed in the refactor skill's `references/proving.md`, under "Tests".

## When the map misses

When a test you would expect isn't picked, grep `Tests/` for the changed type's name and add that suite by name.
When a new source or test file appears, add it to the table here and to the `case` table in `scripts/related.sh`.
