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
  `Tools/build.sh test --filter '<A>|<B>'`: the dev build (the debug configuration with `-O`, in `.build-dev`). It
  rebuilds a one-file edit in about 20 s and runs the CPU-stepped physics suites as fast as release does.
* `--base <rev>` takes the changes since a revision instead, for example `--base main` for a whole branch.
* `--dry-run` prints the suites and the uncovered files and runs nothing.
* `related.sh CityTests BuildingTests` runs the suites you name and skips the map.

By hand, with the same filter:
```bash
Tools/build.sh test --filter 'CityTests|BuildingTests'
```
In release, when a check needs that exact build: `Tools/release.sh test --filter …` (swift test -c release, after
the modules above an `@inlinable` body that changed are marked for rebuilding, which `swift test` alone wouldn't do).
Release builds are testable (`Package.swift`), so it shares `.build/release` with `Tools/release.sh` and needs no
`-Xswiftc -enable-testing`; but a Swift edit recompiles its whole module there.
For one test, use `--filter CityTests/testThePlanIsSeeded`.

## Map

Rows name files (in any module: `Sources/<Module>/<Feature>/…`, the engine's `Sources/MetalRenderer/<Feature>/…`, the game's `Sources/Game/<Feature>/…`) or folders; a feature's `Editor/` is `Sources/Editors/<Feature>/`. `related.sh` looks a Swift source up by its
name first, then by its folder (`by_name`, `by_folder`).

| Changed | Suites |
|---|---|
| `Settings*.swift`, `SceneSettings` | SettingsTableTests, BenchmarkModesTests |
| `SceneDefinition`, `GameScenes*`, `Scene+Kit` | SceneRegistryTests, SettingsTableTests, BenchmarkModesTests |
| `SceneChange`, `SceneLoadQueue`, `SceneSession` | SceneSwitchTests (the switches on the GPU: the `scene-switching` skill's `switches.py`) |
| `Benchmark*.swift` | BenchmarkModesTests, CapabilitiesTests |
| `Script*.swift`, `SceneCommand`, `Renderer+Scripting`, `Scene+Stage` | ScriptingTests |
| `SceneFile`, `Scene+SceneFile`, `Renderer+Placement` | SceneFileTests, ScriptingTests |
| `Capabilities`, `Upscaler`, `Metal4Backend` | CapabilitiesTests |
| `ShaderSource`, `Pipelines`, `GPUTypes`, `Shaders.metal`, any `Shaders/*.metal` | ShaderSourceTests, KernelVariantsTests |
| `Pipelines` (also its `PipelineCache`) | + PipelineCacheTests (in `LoadActivityTests.swift`) |
| `Shaders/Intersect.metal` (the ray queries) | ShaderSourceTests, KernelVariantsTests, PlantTracingTests |
| `BVH.swift` (the SAH builder over boxes, the clusters' trees) | BVHTests, CacheTests |
| `CacheFile`, `SectionFile`, `BlueNoise` | CacheTests |
| `Building*.swift` (the generator, its floor plans, interiors, styles as data, the store, the editor's parameters and Mutate), `BuiltInBuildings`, `MeshBuilder` | BuildingTests, CityTests, BuildingPlanTests, BuildingEditorTests, BuildingWorkshopTests, WalkerTests |
| `PlanEdits`, `PropLibrary`, `Editors/Buildings/FloorPlanView` (hand edits, glTF props) | BuildingEditorTests, BuildingPlanTests |
| `FurnitureKit` | BuildingPlanTests, BuildingWorkshopTests |
| `Walker`, `InteriorControls`, `InteriorLifts` (walking, doors, switches, lifts) | WalkerTests, BuildingWorkshopTests |
| `Scene+Buildings` (the building workshop), `Scene+Interiors` (buildings into scenes, interiors on demand) | BuildingWorkshopTests, CityTests, WorldTests, WalkerTests |
| `Editors/Buildings/*` (the SwiftUI panel, the Floor Plan window) | BuildingEditorTests covers its model; the views: prove with the app |
| `CityPlan`, `Scene+City` | CityTests, BuildingTests |
| `Scene+Stress` | StressSceneTests |
| `Crowd*.swift`, `SkinnedCharacter`, `Scene+Crowd`, `Shaders/Crowd.metal` | CrowdTests, FBXTests, CharacterBaseTests, CharacterFaceTests, CharacterHairTests (`SkinnedCharacter`: + MuscleTests, the rig's poses; the face and hair passes on the GPU: `METALRENDERER_CROWD_CHECK=1` with `-m characters`) |
| `Character*.swift` (DNA, base body, morphs, face rig, builder, params, store), `Face*.swift` (the sculpted head, eyes, teeth), `Editors/Characters/*` | CharacterDNATests, CharacterBaseTests, CharacterFaceTests, CharacterSkinTests, CharacterHairTests, CharacterEditorTests (the editor's views: prove with the app) |
| `CharacterSkin` (skin UVs and textures), `CharacterHair*` (strands, caps) | CharacterSkinTests, CharacterHairTests (the skin shading in `Shaders/Hair.metal`: images, `-m characters`) |
| `Scene+Characters` (the character workshop) | CharacterBaseTests, CharacterHairTests |
| `FBXReader` | FBXTests |
| `Foliage*.swift`, `Scene+Forest` | FoliageTests, ForestTests, FoliageRuntimeTests (all three in `FoliageTests.swift`), PlantGoldenTests, PlantCatalogTests |
| `Plants/Growth/*` (the growth simulation, its light, the mesher, the traced leaf outlines, the twigs) | GrowerTests, MesherTests, TwigTests, PlantGoldenTests, FoliageTests, PlantEditorTests |
| `Plant*.swift` (species as data, curves, habitats, the store, the editor's parameters and Mutate, programs, graphs, their Swift and compiler) | PlantGoldenTests, PlantCatalogTests, PlantWorkshopTests, PlantEditorTests, PlantProgramTests, PlantCompilerTests, PlantSwiftTests, FoliageTests, ForestTests |
| `Scene+Plants`, `Scene+PlantPreview` (the plant workshop and its stage) | PlantWorkshopTests, PlantGoldenTests, RealismTests |
| the backdrop (`Scene.backdrop`, `Uniforms.backdrop`, Trace/PathTrace misses), `RenderSettings.firstLaunch` | PlantWorkshopTests, SettingsTableTests |
| `Editors/Plants/*` (the SwiftUI panel) | PlantEditorTests covers its model; the views: prove with the app |
| `PlantTracing`, `Shaders/Foliage.metal` (the plants' variants, the wind) | PlantTracingTests, FoliageTests, ForestTests, FoliageRuntimeTests (the shader: + the shader pair) |
| `VoxelGrids`, `VoxelLOD` | FoliageRuntimeTests, SceneBuffersTests |
| `Modeling/*` (the Modeller: mesh, ops, transforms, modifiers, sculpt, UVs, files, viewport), `Editors/Modeling/*`, `MetalRenderer/Modeling/*` | ModelingMeshTests, ModelingIOTests, ModelingOpsTests, ModelingTransformTests, ModelingModifierTests, ModelingSculptTests, ModelingDynTopoTests, ModelingViewportTests, ModelingEditorTests (+ SceneFileTests for `Scene+ModelAsset`) |
| `SDF*.swift`, `Scene+Shapes`, `Shaders/SDF.metal` | SDFTests, SceneBuffersTests, PhysicsTests, CharacterBaseTests (sparse surface nets) (the shader: SDFTests + PhysicsTests + the shader pair) |
| `Physics*.swift`, `Scene+Physics`, `Scene+Ragdolls`, `Scene+Hair`, `Scene+Soft`, `Scene+Muscles`, `Shaders/Physics.metal` | PhysicsTests, RagdollTests, HairTests, SoftBodyTests, MuscleTests, FluidTests (the shader: + the shader pair) |
| `Cars/` (the physics', the engine's and the game's: `Physics+Cars`, `Car*.swift`, `Scene+Cars`, `Scene+CarGround`, `CarPlayer`, `CarDamage`) | CarTests, CarDamageTests, CarContactTests, PhysicsThreadsTests |
| `FluidSurface`, `Scene+Fluids`, `Shaders/Fluid.metal`, `Shaders/FluidSurface.metal`, `Shaders/Liquid.metal` | FluidTests (the shaders: + the shader pair) |
| `Particles`, `ParticleMath`, `ParticlesGPU`, `ParticleTextures`, `Scene+Particles`, `Scene+Effects`, `Shaders/ParticleSim.metal`, `Shaders/ParticleLight.metal`, `Shaders/ParticleTrace.metal` | ParticleTests VFXTests (the shaders: + the shader pair) |
| `VFX/*` (the effects' graphs, `Scene+Stage`), `ShadersVFX.metal`, `LegacyEffects` (the golden test's fixture) | VFXTests ParticleTests (`ShadersVFX`: + ShaderSourceTests) |
| `Editors/VFX/*` (the VFX editor), `VFX/VFXLive` (its edits in the running scene) | VFXEditorTests (`VFXLive`: + VFXTests ParticleTests) |
| `App/GraphCanvas` (the graph editors' shared canvas) | VFXEditorTests, MaterialEditorTests, ProjectGraphTests |
| `ProjectGraph/*` (with `Editors/ProjectGraph/`) (the Project Graph: outlines, overrides, the graph, its layouts, its window) | ProjectGraphTests covers the model; the views: `PROJECT_GRAPH_PNG=<folder>` draws them (and the 3D cone into a texture); `-m outlines` writes every scene's outline |
| `Scene.swift`, `Scene+City`, `Scene+Forest`, `Scene+Physics` (the builders' outline tags) | their own suites and ProjectGraphTests |
| `SceneNavigation.swift`, `SceneGizmo.swift` (the scene view's camera about its pivot, the gizmo) | SceneNavigationTests; the gizmo's pictures: `SCENE_GIZMO_PNG=<folder>`; the mouse itself (Renderer's input) by hand |
| `DayClock.swift`, `DayBar.swift` (the day as a clock, holding it, the day bar) | DayClockTests; the bar's pictures: `DAY_BAR_PNG=<folder>`; the bar's clicks in the window by hand |
| `MaterialGraph/*` (Sources/Materials's and the engine's), `MaterialShaders/*`, `ShadersMaterial*.metal` (the Material Designer's graphs, engine, shader code) | MaterialGraphTests, MaterialEngineTests, MaterialEditorTests, MaterialDisplacementTests |
| `Editors/MaterialGraph/*` (the Material Designer's window) | MaterialEditorTests covers its model; the views: `MATERIAL_EDITOR_PNG=<folder>` draws them |
| `Scene+Procedural`, `Scene+Materials` (procedural materials, the material workshop), `Shaders/Procedural.metal`, `Shaders/Pick.metal` | MaterialEditorTests, SceneBuffersTests (the shaders: ShaderSourceTests, KernelVariantsTests, MaterialGraphTests); renders: `-m materials`, `-m matedit` |
| `MuscleAtlas`, `SkeletonAtlas` | MuscleTests (the écorché and its skeleton), CharacterBaseTests (BodySurface) |
| `HairBSDF.swift`, `Shaders/Hair.metal` | HairTests (the shader: + the shader pair) |
| `GLTFLoader` | GLTFLoaderTests |
| `ProceduralTextures`, `MaterialTextures` | ProceduralTextureTests |
| `Scene.swift` and its parts (`Scene+Animation`, `+GPUData`, `+Construction`, `+EmissiveLights`, `+Models`, `+MeshGenerators`, `+CrowdSpawn`, `+PhysicsWorld`, `SplitMix64`), `SceneBuffers` | SceneBuffersTests (`SceneBuffers`: SDFTests too, for the SDF boxes' descriptors) |
| `LightTree.swift`, `Shaders/LightTree.metal` | LightTreeTests (the shader: plus the shader pair) |
| `TextureStreamer` | TextureStreamerTests |
| `SourceTree` (where the shaders, assets and fixtures are found) | ShaderSourceTests, EXRImageTests, MaterialGraphTests |
| `LoadActivity` (the loading overlay's model) | LoadActivityTests (the overlay itself, `LoadingOverlay`: none, it is AppKit) |
| `World+Water` | WorldTests, WaterTests |
| `World*.swift`, `Scene+World`, `Terrain` | WorldTests, SceneBuffersTests |
| `Water/*`, `Scene+Water`, `Renderer+Water`, `Terrain/TerrainWater` | WaterTests (the shaders `Water.metal`, `WaterCommon.metal`: plus ShaderSourceTests, KernelVariantsTests; prove the look with images: `METALRENDERER_BENCH=water`, `waterunder`, `waterperf`) |
| `Terrain/*` (Sources/Landscape's and the engine's), `Scene+Terrain*`, `Renderer+Terrain`, `Scene+Rocks` | TerrainDocumentTests, TerrainEditorTests |
| `Editors/Terrain/*` | TerrainEditorTests |
| `Showcase.swift`, `Scene+Showcase` | ShowcaseTests |
| `VirtualGeometryBuilder` (its cache file) | CacheTests, VGStreamerTests |
| `MeshSimplifier`, `MeshClusterizer` (the builder's steps; characters' LODs) | CacheTests, VGStreamerTests, CharacterBaseTests |
| `VGStreamer`, `VirtualGeometry` (streaming, the DAG's group records) | VGStreamerTests, VGCutTests |
| `VirtualTracing` (virtual geometry in Metal's structures) | VGCutTests, VGStreamerTests (+ prove with images: no suite traces it) |
| `TraceScene`, `Renderer`, `RenderTargets`, `Renderer+*` (but the ones in a feature folder: theirs) | none: prove with images (the offscreen skill) |
| `VirtualBLAS` (its cut), `Shaders/VirtualGeometry.metal` | VGCutTests (the shaders: plus the shader pair) |
| `Tests/MetalRendererTests/<Folder>/XTests.swift` | XTests |
| `Package.swift`, a shared test helper | all suites: the one case where the full run is right |

What each suite guards is listed in the refactor skill's `references/proving.md`, under "Tests".

## When the map misses

When a test you would expect isn't picked, grep `Tests/` for the changed type's name and add that suite by name.
When a new source or test file appears, add it to the table here and to the `case` table in `scripts/related.sh`.
