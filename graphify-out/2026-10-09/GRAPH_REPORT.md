# Graph Report - MetalRenderer  (2026-10-09)

## Corpus Check
- 297 files · ~1,611,038 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 29 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 3)

## Summary
- 7992 nodes · 24866 edges · 283 communities (229 shown, 54 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3795 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f82d2d6a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- traceKernel
- PlantCatalog
- common.py
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- LayerSurface
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- SDFVolume
- atrousKernel
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- float4x4
- RasterClusters
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- Camera
- regirBuildKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- .write
- String
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- .build
- AppDelegate
- Crowd
- VirtualGeometry
- SDFShape
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Shaders.metal
- VGBlas
- Types.metal
- Direct Rendering Stress Test 32
- LumenScene
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- CityPlan
- Int32
- simd
- Metal3Pass
- RendererController
- TextureStreamer
- BVHBuilder
- Pipelines
- ab.sh
- LoadActivity
- instanceRecord
- Ray
- VirtualBLAS
- BuildingEditorModel
- SettingsTableTests
- Capabilities
- Float
- FluidParams
- ProceduralTextures
- flagOn
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- MuscleTests
- BuildingAssembler
- float3
- ClusterBox
- SoftModel
- uint4
- Rect
- CaseIterable
- Bool
- FoliageTextures
- BuildingStore
- EnvVariable
- .planFrame
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- NeuralWeights
- Interior
- .meshes
- .library
- Foliage
- same.sh
- Key
- baseline.sh
- BuildingPlan
- .buildWorld
- export.py
- Raster.metal
- Int
- FluidSystem
- lumenCardRadiosityKernel
- DebugInfo
- PlantWind
- PlantEditorTests
- Kind
- Benchmark
- RoomType
- RasterVGParams
- VoxelLOD
- BlueNoise
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- MEMORY.md
- RenderView
- .writeDescriptors
- VSMCounters
- .load
- Hit
- QuartzCore
- MeshBuilder
- ComputePass
- DatasetSpec
- Curve
- Post.metal
- Furnisher
- BuildingSpec
- DebugPanel
- .part
- TraceScene
- Intersect.metal
- AppKit
- Lift
- related.sh
- VirtualMesh
- RTVoxels
- SplitMix64
- VGParams
- CPU (Swift) practices for MetalRenderer
- .add
- FBXError
- VSM.metal
- .draw
- .encodeSceneUpdate
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- .simplify
- Modes
- Building
- VSMParams
- FoliageRuntimeTests
- XCTestCase
- RasterParams
- Role
- Binding
- Neural.metal
- VSMInstance
- ColliderGrid
- train.py
- PlantTracing
- RasterCounters
- SplitMix
- Float
- SDFBox
- Species
- RasterInstance
- RagdollTests
- FurnitureItem
- BenchmarkModesTests
- .floatCapture
- .stages
- LoadingOverlay
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- SceneSettings
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- Hair.metal
- FBXFile
- .grow
- uint
- SkyParams
- LumenParams
- Step 1: safety (A-items), no image change except A3
- LumenMeshSDF
- RenderThread
- SIMD3
- SettingsStore
- HairBSDF
- .commit
- Where things are
- SDFBuffers
- RenderPass4
- PhysicsParams
- Double
- WorldPlace
- Float
- .key
- Clip
- Stage
- PlantEditorPanel
- lumen.py
- GPU (Metal / MSL) practices for MetalRenderer
- Buffer
- Row
- LotRef
- PressButton
- VGRasterInstance
- WallGrid
- PhysicsMuscle
- BuildingEditorPanel
- RasterScene
- VoxelGrids
- vsmFragment
- Tab
- CharacterLibrary
- Kind
- PrimitiveWork
- LightKind
- TrainingSceneTests
- Host
- Batch 5: per-frame CPU
- WindFrame
- PlantSpecies.swift
- Measuring MetalRenderer
- Phyllotaxis
- .end
- LightMotion
- Shape
- demo-video.sh
- make-dataset.sh

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 480 edges
2. `Scene` - 336 edges
3. `Renderer` - 277 edges
4. `PhysicsWorld` - 275 edges
5. `Kernel` - 162 edges
6. `SIMD4` - 152 edges
7. `Foliage` - 151 edges
8. `Benchmark` - 150 edges
9. `simd` - 147 edges
10. `RenderSettings` - 116 edges

## Surprising Connections (you probably didn't know these)
- `Recipes` --references--> `DemoWalk`  [INFERRED]
  .claude/skills/offscreen/SKILL.md → Sources/MetalRenderer/Benchmark+BuildingsDemo.swift
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `Step 0: baseline and a CPU meter` --references--> `DebugInfo`  [INFERRED]
  .claude/memory/plans/audit-backlog.md → Sources/MetalRenderer/DebugPanel.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Albedo Stress Test Reference Components** — tools_eval_refs_stress_ref_albedo_1_5x_stress_test_scene, tools_eval_refs_stress_ref_albedo_1_5x_geometric_shapes, tools_eval_refs_stress_ref_albedo_1_5x_color_palette, tools_eval_refs_stress_ref_albedo_1_5x_spatial_layout [EXTRACTED 1.00]
- **Direct Lighting Rendering Test** — tools_eval_refs_stress_ref_direct_1_5x_direct_lighting, tools_eval_refs_stress_ref_direct_1_5x_geometric_complexity, tools_eval_refs_stress_ref_direct_1_5x_material_properties, tools_eval_refs_stress_ref_direct_1_5x_lighting_quality [EXTRACTED 1.00]
- **Direct Shadow Rendering System** — tools_eval_refs_shadow_ref_direct_point_light_source, tools_eval_refs_shadow_ref_direct_geometric_objects, tools_eval_refs_shadow_ref_direct_shadow_casting [EXTRACTED 1.00]
- **Geometric Primitives Demonstrating Light Interaction** — tools_eval_refs_gi_ref8_indirect_0_5x_red_plane, tools_eval_refs_gi_ref8_indirect_0_5x_green_plane, tools_eval_refs_gi_ref8_indirect_0_5x_white_prism, tools_eval_refs_gi_ref8_indirect_0_5x_yellow_cube, tools_eval_refs_gi_ref8_indirect_0_5x_blue_hemisphere, tools_eval_refs_gi_ref8_indirect_0_5x_pink_prism [EXTRACTED 1.00]
- **Custom Two-Level BVH Construction and Traversal** — readme_custom_ray_tracer, readme_binned_sah_blas, readme_gpu_lbvh_rebuild, readme_single_loop_traversal, readme_virtual_geometry [EXTRACTED 1.00]
- **Three Switchable GI Methods** — readme_radiance_cascades, readme_surfel_gi, readme_path_traced_gi, readme_light_visibility_maps [EXTRACTED 1.00]
- **Background Planes** — tools_eval_refs_gi_ref8_1_5x_red_plane, tools_eval_refs_gi_ref8_1_5x_green_plane, tools_eval_refs_gi_ref8_1_5x_gradient_background [EXTRACTED 1.00]
- **Primary Geometric Shapes** — tools_eval_refs_gi_ref8_1_5x_blue_sphere, tools_eval_refs_gi_ref8_1_5x_yellow_cube, tools_eval_refs_gi_ref8_1_5x_white_sphere, tools_eval_refs_gi_ref8_1_5x_white_pillar [EXTRACTED 1.00]
- **Geometric Primitives Compose Scene** — tools_eval_refs_stress_ref_direct_128_sphere_primitive, tools_eval_refs_stress_ref_direct_128_cube_primitive, tools_eval_refs_stress_ref_direct_128_box_primitive, tools_eval_refs_stress_ref_direct_128_render_scene [EXTRACTED 1.00]
- **Gallery Showcase System** — tools_eval_refs_gallery_ref_closeup_gallery_view, tools_eval_refs_gallery_ref_closeup_steampunk_aesthetic, tools_eval_refs_gallery_ref_closeup_mechanical_design_language, tools_eval_refs_gallery_ref_closeup_pedestal_display_pattern [EXTRACTED 1.00]
- **Direct-Light Sampling and Shadow Denoising Pipeline** — readme_shared_light_helpers, readme_many_lights_sampling, readme_restir_temporal_reuse, readme_shadow_denoiser, readme_composite_kernel [INFERRED 0.85]
- **3D Rendering and Material Reference** — tools_eval_refs_gi_ref8_1_5x_spatial_depth, tools_eval_refs_gi_ref8_1_5x_lighting_model, tools_eval_refs_gi_ref8_1_5x_color_palette [INFERRED 0.85]
- **Stress Test Rendering Methodology** — geometric_primitives_rendering_test, object_density_distribution, color_variation_visual_clarity [INFERRED 0.85]
- **Stress Test Rendering Pipeline** — tools_eval_refs_stress_ref_direct_32_direct_rendering, tools_eval_refs_stress_ref_direct_32_3d_objects, tools_eval_refs_stress_ref_direct_32_lighting [INFERRED 0.85]
- **Global Illumination Rendering Components** — tools_eval_refs_gi_ref8_0_5x_geometric_primitives, tools_eval_refs_gi_ref8_0_5x_material_surfaces, tools_eval_refs_gi_ref8_0_5x_light_source [INFERRED 0.85]

## Communities (283 total, 54 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (39): Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6), AABB, .area, .centroid, .isEmpty, GPUEmissiveTriangle, meshLights, Assembly (+31 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (35): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+27 more)

### Community 3 - "RenderSettings"
Cohesion: 0.08
Nodes (53): Clipboard, Draft, BuildingStyleDef, Choice, FacadeDef, Finish, InteriorDef, MassingDef (+45 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (64): Pass 2: sample + trace (`megaLightsSampleKernel`), clipSegment(), ggxFromDirection(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+56 more)

### Community 5 - "traceKernel"
Cohesion: 0.09
Nodes (31): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), cosineSampleHemisphere(), fireflyScale(), laineKarrasPermutation(), luminance(), makeSampler(), nestedUniformScramble() (+23 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.08
Nodes (13): PlantCatalog, .all, .count, .covers, File, Foliage.SpeciesDef, .fingerprint, .launch (+5 more)

### Community 7 - "common.py"
Cohesion: 0.11
Nodes (17): aces(), array_path(), clip_dirs(), display(), frames(), load(), matches(), paused() (+9 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.11
Nodes (52): fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf(), fluidCellsClearKernel(), fluidCellSortKernel() (+44 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.07
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 10 - "PlantEditorModel"
Cohesion: 0.09
Nodes (14): PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key, .savedDef (+6 more)

### Community 11 - "LayerSurface"
Cohesion: 0.16
Nodes (7): LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (19): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, rcClearAmbientKernel(), rcEvalSH() (+11 more)

### Community 13 - "FramePlan"
Cohesion: 0.17
Nodes (13): B. Remaining per-frame CPU, D. Structure / duplication, 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev (+5 more)

### Community 16 - "translate"
Cohesion: 0.16
Nodes (13): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, rotate(), scale(), translate(), FogVolume, .gpu, LightPose (+5 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (3): SDFVolume, .hi, SDFTests

### Community 18 - "atrousKernel"
Cohesion: 0.21
Nodes (11): Design, Light influence range (new; nothing in the codebase has a cutoff), Pass 1: tile cull (`megaLightsCullKernel`), Pass 3: resolve (`megaLightsResolveKernel`, full res), atrousKernel(), depthGradient(), geometryWeights(), readNoisy() (+3 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (24): fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel(), fogMedium() (+16 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (26): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+18 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (59): makeRay(), pathTraceKernel(), PathTraceParams, bounds, config, samples, PTFog, bounds (+51 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (4): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount

### Community 23 - "float4x4"
Cohesion: 0.13
Nodes (12): Prop, GPUMaterial, float4x4, Hall, Loop, .length, Props, Zone (+4 more)

### Community 24 - "RasterClusters"
Cohesion: 0.11
Nodes (7): Params, RasterClusters, .drawnByCamera, .stats, .summary, GPUCut, VGCutTests

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (32): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+24 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (11): GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount, SkinnedCharacter (+3 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (16): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+8 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (140): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+132 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (8): Settings: `SettingsTable.swift`, Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (48): Batch 3: launch time, To do on the M4 Max, 8. Pipelines and resources, SkyImage, Launch, GPUSkyParams, done, LoadOptions (+40 more)

### Community 31 - "Camera"
Cohesion: 0.10
Nodes (8): GPUMesh, Camera, .forward, .right, .up, .worldToView, PlantStats, RasterSceneTests

### Community 32 - "regirBuildKernel"
Cohesion: 0.11
Nodes (18): quantizeUV(), regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup() (+10 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (16): emptyReservoir(), packReservoir(), Reservoir, element, M, uv, visible, W (+8 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (31): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+23 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "GPUTypes.swift"
Cohesion: 0.07
Nodes (36): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUInstanceData, GPUJointMatrix, GPUMuscle, GPUPathTraceParams, GPUPhysicsConstraint (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.09
Nodes (11): CryptoKit, GeneratedCache, Hasher, SectionFile, Stored, .array, .count, mapped (+3 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (55): physActivate(), physCell(), physColourPairs(), physColoursAround(), physDampJoint(), physDirection(), physDistance2(), physFlat() (+47 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.13
Nodes (10): LeafAnchor, LeafShape, blade, kite, needle, Mesh, .leafTriangles, .triangles (+2 more)

### Community 42 - "String"
Cohesion: 0.03
Nodes (76): .name, CatalogRegistry, Section, CityStyle, mixed, modern, office, oldtown (+68 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (17): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, VSMSettings, Kind, sphere (+9 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (22): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+14 more)

### Community 45 - "View"
Cohesion: 0.10
Nodes (35): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+27 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (8): Blue Hemisphere, Green Vertical Plane, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism, Yellow Cube

### Community 47 - ".build"
Cohesion: 0.10
Nodes (11): .e, Heightfield, .hi, MeshSDF, .bytes, .hi, .storedBricks, MeshSDFBuilder (+3 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.12
Nodes (12): Build, Params, VGPipelines, VirtualGeometry, .clusterCount, .groupCount, .meshCount, .pool (+4 more)

### Community 51 - "SDFShape"
Cohesion: 0.06
Nodes (31): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, .pending, Kind, arrays, block (+23 more)

### Community 52 - "SceneKind"
Cohesion: 0.04
Nodes (42): SceneKind, area, buildings, .cameraFromScene, city, cityNight, cornell, crowd (+34 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.07
Nodes (15): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+7 more)

### Community 55 - "Color Bleeding from Walls to Objects"
Cohesion: 0.40
Nodes (6): Color Bleeding from Walls to Objects, Direct and Indirect Illumination Effects, Geometric Primitives (Cylinder, Cube, Sphere, Rectangular Blocks), Global Illumination Reference Scene, Primary Light Source, Varied Material Surfaces and Reflectivity

### Community 56 - "3D Graphics Stress Test Scene"
Cohesion: 0.33
Nodes (5): Albedo Reference Image 1.5x, Color Palette Distribution, Geometric Shapes, 3D Spatial Layout, 3D Graphics Stress Test Scene

### Community 57 - "Direct Lighting Reference Render"
Cohesion: 0.40
Nodes (5): Geometric Complexity, Lighting Quality and Shadows, Material Properties and Colors, Direct Lighting Reference Render, Rendering Stress Test

### Community 59 - "MuscleAtlas"
Cohesion: 0.07
Nodes (30): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+22 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (77): glassKernel(), glassReflection(), reflectionHitRadiance(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow() (+69 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (19): VGBlas, attrs, pad0, pad1, pad2, triangles, tris, VGClusterView (+11 more)

### Community 63 - "Types.metal"
Cohesion: 0.05
Nodes (36): EmissiveTriangle, e1, e2, uv12, v0, InstanceBlockRef, records, MaterialTexture (+28 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (4): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Direct Rendering Stress Test 32

### Community 65 - "LumenScene"
Cohesion: 0.14
Nodes (9): Baked, bricks, GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes (+1 more)

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.06
Nodes (12): .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged, Content, TraceSceneArgs, VGView, VirtualTracing (+4 more)

### Community 73 - "CityPlan"
Cohesion: 0.07
Nodes (29): .entry, .well, Core, .all, .stairPlan, Mode, backCore, frontCore (+21 more)

### Community 74 - "Int32"
Cohesion: 0.14
Nodes (5): Int32, GPUFluidParams, GPUFluidParticle, LocalIds, MeshClusterizer

### Community 76 - "Metal3Pass"
Cohesion: 0.07
Nodes (4): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass

### Community 77 - "RendererController"
Cohesion: 0.08
Nodes (18): .buildingPlan, .buildingStats, .cameraPosition, .walker, .plantStats, RendererController, .debugActive, .debugInfo (+10 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.07
Nodes (15): LoadStep, Entry, Level, SparseMapping, TextureStreamer, .details, .levelProgress, .placement (+7 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (9): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+1 more)

### Community 80 - "Pipelines"
Cohesion: 0.07
Nodes (22): Pipelines: `Pipelines.swift`, Things that are not structures yet, Where new code belongs, Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses (+14 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.11
Nodes (11): Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled, Snapshot (+3 more)

### Community 83 - "instanceRecord"
Cohesion: 0.14
Nodes (26): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+18 more)

### Community 84 - "Ray"
Cohesion: 0.21
Nodes (13): boxCandidate(), clusterWalk(), intersectDistance(), octDecode(), Ray, direction, origin, tmax (+5 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.16
Nodes (10): Built, CutInput, Entry, VirtualBLAS, .instanceCount, .isBusy, .meshCount, .sourceTriangles (+2 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.05
Nodes (21): BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def, .inWorkshop, .isBuiltIn, .isDirty (+13 more)

### Community 87 - "SettingsTableTests"
Cohesion: 0.10
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 88 - "Capabilities"
Cohesion: 0.20
Nodes (5): Capabilities: `Capabilities.swift`, Capabilities, .summary, CapabilitiesTests, .none

### Community 89 - "Float"
Cohesion: 0.14
Nodes (9): Card, Carve, Graft, Grower, LeafRecipe, Level, Recipe, Skeleton (+1 more)

### Community 90 - "FluidParams"
Cohesion: 0.06
Nodes (30): FluidMpmPart, a0, a1, a2, sp, v, FluidParams, counts (+22 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.18
Nodes (3): Maps, ProceduralTextures, ProceduralTextureTests

### Community 92 - "flagOn"
Cohesion: 0.20
Nodes (13): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), finiteSample() (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (3): UpscaleInputs, Upscaler, View

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (38): groupElement(), cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link (+30 more)

### Community 95 - "FluidTests"
Cohesion: 0.09
Nodes (12): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+4 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (46): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+38 more)

### Community 99 - "BuildingAssembler"
Cohesion: 0.08
Nodes (22): BuildingAssembler, BuildingTier, .top, Cell, .center, .width, Opening, Footprint (+14 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (31): physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient(), PhysCandidate, n (+23 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (13): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+5 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (8): GPUPhysicsParticle, .particleCellSize, Flesh, NearCache, SoftModel, .near, .radius, SoftBodyTests

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (51): PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad, shape (+43 more)

### Community 104 - "Rect"
Cohesion: 0.13
Nodes (13): Kind, door, entrance, glazed, lift, open, PlanDoor, PlanRoom (+5 more)

### Community 105 - "CaseIterable"
Cohesion: 0.02
Nodes (85): Scope, all, floor, Tool, door, look, merge, split (+77 more)

### Community 106 - "Bool"
Cohesion: 0.06
Nodes (26): .reservoirCount, Bool, .envText, Control, checkbox, custom, popup, slider (+18 more)

### Community 107 - "FoliageTextures"
Cohesion: 0.15
Nodes (10): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+2 more)

### Community 108 - "BuildingStore"
Cohesion: 0.19
Nodes (7): interior, .launch, BuildingStore, .encoder, .folder, File, OverridesFile

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 110 - ".planFrame"
Cohesion: 0.06
Nodes (21): Denoise, Integration (follow the ReSTIR wiring; refactor-skill rules), MetalKit, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUMegaLightsParams, GPUPostParams (+13 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (10): CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey, EnvironmentValues, .editorDrag (+2 more)

### Community 112 - "WorldTile"
Cohesion: 0.10
Nodes (10): .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, WorldTile (+2 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (33): sdfEval(), sdfJoin(), sdfMarch(), SDFNode, k, kind, material, op (+25 more)

### Community 114 - "Metal"
Cohesion: 0.09
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.07
Nodes (45): physAcross(), physAnchorTurnWeight(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular, info (+37 more)

### Community 117 - "NeuralWeights"
Cohesion: 0.10
Nodes (11): Header, NeuralInputs, NeuralPipelines, NeuralUpscaler, .factor, .outputHeight, .outputWidth, NeuralWeights (+3 more)

### Community 118 - "Interior"
Cohesion: 0.13
Nodes (13): Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder, LiftShaft, Maker (+5 more)

### Community 119 - ".meshes"
Cohesion: 0.11
Nodes (7): Batch 6: load time, GLTFModel, .triangleCount, Light, Entry, File, PropLibrary

### Community 120 - ".library"
Cohesion: 0.09
Nodes (19): Age, mature, sapling, young, Bone, Part, Plant, .height (+11 more)

### Community 121 - "Foliage"
Cohesion: 0.17
Nodes (11): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+3 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (11): Keys, hi, lo, Foliage.Curve, Key, crown, linear, points (+3 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.20
Nodes (6): DemoWalk, Point, CameraTrack, .duration, Key, BuildingPlan

### Community 126 - ".buildWorld"
Cohesion: 0.08
Nodes (17): SurfaceMaterial, .uvScale, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+9 more)

### Community 127 - "export.py"
Cohesion: 0.12
Nodes (8): golden(), main(), write_nnw(), conv(), DenoisingUpscaler, prepare(), to_linear(), warp()

### Community 128 - "Raster.metal"
Cohesion: 0.17
Nodes (18): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+10 more)

### Community 129 - "Int"
Cohesion: 0.07
Nodes (12): Card, GPULumenCard, LumenCards, .megabytes, Int, .envText, BuddyAllocator, Group (+4 more)

### Community 130 - "FluidSystem"
Cohesion: 0.18
Nodes (11): .surfaceCapacity, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims, .domain, .mass (+3 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "DebugInfo"
Cohesion: 0.15
Nodes (11): 9. Shader helpers: use them, don't copy, DebugInfo, VirtualGeometry, blas, clusters, off, .triangles, TraversalStats (+3 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (40): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+32 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.12
Nodes (3): PlantMutate, Host, PlantEditorTests

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.06
Nodes (14): Render something: `scripts/render.sh`, Benchmark modes: `Benchmark+Modes.swift`, Benchmark, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig (+6 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (34): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+26 more)

### Community 138 - "RasterVGParams"
Cohesion: 0.11
Nodes (17): RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad (+9 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.17
Nodes (4): .megabytes, Entry, VoxelLOD, .megabytes

### Community 140 - "BlueNoise"
Cohesion: 0.16
Nodes (4): BlueNoise, .cacheURL, SplitMix64, CacheFile

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (18): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+10 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (12): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, rasterVGCutKernel(), rasterVGMeshArgsKernel(), rasterVGRetestKernel(), rvgDraw(), rvgOwners() (+4 more)

### Community 143 - "liquidKernel"
Cohesion: 0.13
Nodes (8): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial()

### Community 144 - "MEMORY.md"
Cohesion: 0.14
Nodes (6): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (3): InputHandler, RenderView, .acceptsFirstResponder

### Community 146 - ".writeDescriptors"
Cohesion: 0.17
Nodes (3): Tests, Wind, PlantTracingTests

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - ".load"
Cohesion: 0.11
Nodes (10): LoadError, unreadable, GLTFError, .description, NeuralError, format, memory, Failure (+2 more)

### Community 149 - "Hit"
Cohesion: 0.15
Nodes (12): committedCurve(), countedHit(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.11
Nodes (5): Combine, MetalFX, QuartzCore, Array, Headless

### Community 151 - "MeshBuilder"
Cohesion: 0.14
Nodes (8): .triangleCount, Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount

### Community 152 - "ComputePass"
Cohesion: 0.09
Nodes (15): ComputePass, Step, GPUNeuralParams, FluidGPU, .summary, Steps, System, Group (+7 more)

### Community 153 - "DatasetSpec"
Cohesion: 0.12
Nodes (12): CameraDrift, DatasetClip, DatasetFrame, .cameraPose, DatasetSpec, .clipList, 1. Make the dataset, 2. Train (+4 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (14): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+6 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (11): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+3 more)

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (11): Furnisher, FurnishPalette, Light, Prefer, any, away, corner, middle (+3 more)

### Community 157 - "BuildingSpec"
Cohesion: 0.16
Nodes (8): BuildingSpec, .style, Detail, flat, full, FloorPlan, .height, BuildingPlanTests

### Community 158 - "DebugPanel"
Cohesion: 0.08
Nodes (10): DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, Backend, auto, cpu (+2 more)

### Community 159 - ".part"
Cohesion: 0.22
Nodes (6): CharacterImporter, Part, Skeleton, .bindPositions, .bindRotations, SourceClip

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.20
Nodes (18): anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit(), commitCurve(), commitCurveCandidate(), countedQuery() (+10 more)

### Community 162 - "AppKit"
Cohesion: 0.14
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (16): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Switch, Lift (+8 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "VirtualMesh"
Cohesion: 0.13
Nodes (7): Cluster, Group, .isRoot, VGCluster, VirtualGeometryBuilder, VirtualMesh, VGStreamerTests

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (28): vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere (+20 more)

### Community 169 - "CPU (Swift) practices for MetalRenderer"
Cohesion: 0.09
Nodes (18): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Proving a refactor changed nothing, Scorers and other tools (+10 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (3): Hash, .value, PlantGoldenTests

### Community 171 - "FBXError"
Cohesion: 0.24
Nodes (6): FBXError, .description, BlobReader, Mapping, controlPoint, polygonVertex

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (14): shadowVisible(), vsmBoxPages(), vsmClip(), vsmClipLocal(), vsmCullKernel(), vsmDebugKernel(), vsmEntry(), vsmFootprint() (+6 more)

### Community 174 - ".encodeSceneUpdate"
Cohesion: 0.05
Nodes (13): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameEncoder, Metal3Frame, PrimitiveRefit, RenderAttachments, TLASUpdate, .descriptor, Frame (+5 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.20
Nodes (8): FloorPlanView, .body, .help, .picked, .status, .storeys, .toolbar, Mapping

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (14): VSMView, flags, kind, level, light, origin, pages, params (+6 more)

### Community 177 - "PlantParam"
Cohesion: 0.21
Nodes (4): .body, PlantParam, .isInteger, PlantParams

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (13): VSMScene, bias, camera, flags, forward, lightCount, lights, pool (+5 more)

### Community 180 - "uint"
Cohesion: 0.32
Nodes (10): vsmAllocKernel(), vsmChunksKernel(), vsmClearVertex(), vsmFreeKernel(), vsmPageClip(), vsmResetKernel(), vsmSettleKernel(), vsmTag() (+2 more)

### Community 181 - ".simplify"
Cohesion: 0.15
Nodes (6): .cells, MeshSimplifier, Quadric, SkinOptions, SkinShell, .edges

### Community 182 - "Modes"
Cohesion: 0.12
Nodes (17): Batch 1: shader file split, Batch 2: shader duplication, Batch 4: small GPU items, Batch 7: housekeeping, C. GPU, Context, MetalGI: the rest of the audit backlog, in seven batches, Not in this plan (+9 more)

### Community 183 - "Building"
Cohesion: 0.07
Nodes (24): Building, BuildingGenerator, Module, Slot, accent, blind, dark, floor (+16 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "XCTestCase"
Cohesion: 0.13
Nodes (8): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, ForestTests, NeuralUpscalerTests, .shaders, PlantWorkshopTests

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "Binding"
Cohesion: 0.09
Nodes (24): Clip, graft, habitat, leaves, level, look, Clipboard, .body (+16 more)

### Community 190 - "Neural.metal"
Cohesion: 0.18
Nodes (10): neuralConvKernel(), neuralFinishKernel(), NeuralParams, channels, frame, shape, size, neuralPoolKernel() (+2 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.26
Nodes (6): ColliderGrid, Input, Moving, Walker, .eyePosition, .height

### Community 193 - "train.py"
Cohesion: 0.13
Nodes (6): Sequences, display(), loss_fn(), step(), masked_l1(), run_sequence()

### Community 194 - "PlantTracing"
Cohesion: 0.12
Nodes (7): To do on the M4 Max, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 197 - "Float"
Cohesion: 0.15
Nodes (5): Cloth, PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "Species"
Cohesion: 0.18
Nodes (8): Species, .description, .hasBoughs, .isTree, Habitat, Ramp, TreePicker, .isEmpty

### Community 200 - "RasterInstance"
Cohesion: 0.20
Nodes (9): RasterInstance, corners, indices, w, x, y, RasterMesh, hi (+1 more)

### Community 204 - ".floatCapture"
Cohesion: 0.12
Nodes (3): DatasetCapture, inputs, reference

### Community 205 - ".stages"
Cohesion: 0.17
Nodes (4): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "float4"
Cohesion: 0.06
Nodes (39): quatMul(), physBetween(), physBreeze(), physConj(), PhysicsFleshFibre, compliance, g, muscle (+31 more)

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 213 - "SceneSettings"
Cohesion: 0.11
Nodes (3): SceneSettings, SceneBuffersTests, StressSceneTests

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "Hair.metal"
Cohesion: 0.10
Nodes (35): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+27 more)

### Community 220 - "FBXFile"
Cohesion: 0.12
Nodes (13): Compression, Children, Connection, Contents, FBXArrayElement, invalid, unsupported, FBXFile (+5 more)

### Community 222 - "uint"
Cohesion: 0.30
Nodes (10): candidate(), candidateIndex(), candidatePart(), card(), committed(), committedPart(), instance(), intersectAny() (+2 more)

### Community 223 - "SkyParams"
Cohesion: 0.07
Nodes (29): Light, axis, color, params, positionRadius, Material, albedo, emission (+21 more)

### Community 224 - "LumenParams"
Cohesion: 0.25
Nodes (6): LumenParams, grid, options, screen, sdf, tuning

### Community 225 - "Step 1: safety (A-items), no image change except A3"
Cohesion: 0.18
Nodes (10): Backlog: the rest of the audit, Context, E. Load time, Earlier plan (done on 2026-10-03): safety fixes + market CPU wins, F. Housekeeping, Step 0: baseline and a CPU meter, Step 1: safety (A-items), no image change except A3, Step 2: cheap per-frame and load wins (+2 more)

### Community 226 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (13): LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo, plant (+5 more)

### Community 228 - "SIMD3"
Cohesion: 0.08
Nodes (19): Atmosphere, GPUPhysicsShape, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind (+11 more)

### Community 232 - "Where things are"
Cohesion: 0.12
Nodes (9): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, Where things are, BuildingMutate, BuildingParams (+1 more)

### Community 233 - "SDFBuffers"
Cohesion: 0.24
Nodes (3): BoxData, SDFBuffers, .buffers

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Double"
Cohesion: 0.09
Nodes (19): Double, World, .anchorTile, .start, Block, City, Flora, Ground (+11 more)

### Community 238 - "Float"
Cohesion: 0.19
Nodes (4): Event, callLift, flashlight, lights

### Community 240 - "Clip"
Cohesion: 0.22
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 241 - "Stage"
Cohesion: 0.13
Nodes (14): Particles, bubbles, dust, embers, none, runes, Stage, crypt (+6 more)

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (3): PlantEditorPanel, .isVisible, .wasVisible

### Community 244 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.22
Nodes (8): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, GPU (Metal / MSL) practices for MetalRenderer, rtCutout()

### Community 245 - "Buffer"
Cohesion: 0.22
Nodes (4): Buffer, mappings, metal3, metal4

### Community 246 - "Row"
Cohesion: 0.15
Nodes (8): Model, heading, item, Row, State, failed, running, streaming

### Community 247 - "LotRef"
Cohesion: 0.16
Nodes (10): LotRef, .isWorkshop, .key, .title, PlanEdit, .changesRooms, StoreySel, all (+2 more)

### Community 248 - "PressButton"
Cohesion: 0.22
Nodes (3): PressButton, .body, SwiftUI

### Community 250 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 251 - "WallGrid"
Cohesion: 0.29
Nodes (7): WallGrid, .alongX, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "BuildingEditorPanel"
Cohesion: 0.22
Nodes (3): BuildingEditorPanel, .isVisible, .wasVisible

### Community 254 - "RasterScene"
Cohesion: 0.28
Nodes (3): RasterScene, .megabytes, RasterTargets

### Community 255 - "VoxelGrids"
Cohesion: 0.17
Nodes (8): FoliageVoxels, Grid, Piece, Plant, BoxData, VoxelGrids, .buffers, .megabytes

### Community 258 - "Tab"
Cohesion: 0.25
Nodes (8): Tab, facade, floors, furnish, look, massing, rooms, site

### Community 259 - "CharacterLibrary"
Cohesion: 0.29
Nodes (4): BlobWriter, CharacterLibrary, .directory, concurrently()

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (5): Kind, furniture, glass, solid, stair

### Community 262 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 266 - "WindFrame"
Cohesion: 0.31
Nodes (4): PlantKey, WindFrame, .plantKey, .poseKey

### Community 270 - "Measuring MetalRenderer"
Cohesion: 0.17
Nodes (10): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer (+2 more)

### Community 272 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 275 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 279 - "Shape"
Cohesion: 0.67
Nodes (3): Shape, box, sphere

## Knowledge Gaps
- **1772 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1767 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2430 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **54 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `float4x4`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Camera`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `View`, `.build`, `Crowd`, `VirtualGeometry`, `SDFShape`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `LumenScene`, `VirtualTracing`, `CityPlan`, `Int32`, `Metal3Pass`, `RendererController`, `TextureStreamer`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `SettingsTableTests`, `Float`, `ProceduralTextures`, `Upscaler`, `FluidTests`, `PhysicsTests`, `MuscleTests`, `BuildingAssembler`, `SoftModel`, `Rect`, `CaseIterable`, `Bool`, `FoliageTextures`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `.meshes`, `.library`, `Foliage`, `BuildingPlan`, `.buildWorld`, `FluidSystem`, `DebugInfo`, `PlantEditorTests`, `Benchmark`, `RoomType`, `VoxelLOD`, `BlueNoise`, `.writeDescriptors`, `QuartzCore`, `MeshBuilder`, `ComputePass`, `DatasetSpec`, `Curve`, `Furnisher`, `BuildingSpec`, `DebugPanel`, `.part`, `Lift`, `VirtualMesh`, `SplitMix64`, `FBXError`, `.encodeSceneUpdate`, `FloorPlanView`, `PlantParam`, `.simplify`, `Modes`, `Building`, `FoliageRuntimeTests`, `Role`, `Binding`, `ColliderGrid`, `PlantTracing`, `Float`, `Species`, `RagdollTests`, `FurnitureItem`, `BenchmarkModesTests`, `.floatCapture`, `.stages`, `Terrain`, `SceneSettings`, `FBXFile`, `.grow`, `SIMD3`, `.commit`, `Where things are`, `SDFBuffers`, `RenderPass4`, `Double`, `WorldPlace`, `Float`, `.key`, `Row`, `LotRef`, `.keep`, `RasterScene`, `VoxelGrids`, `CharacterLibrary`, `PrimitiveWork`, `LightKind`, `TrainingSceneTests`, `Batch 5: per-frame CPU`, `WindFrame`, `Phyllotaxis`, `.addRagdoll`, `.dispatchThreadgroups`, `.torusKnotMesh`?**
  _High betweenness centrality (0.328) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `float4x4`, `RasterClusters`, `SettingsPanel`, `Renderer`, `Camera`, `GPUTypes.swift`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `.build`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `SDFShape`, `SceneKind`, `PhysicsWorld`, `LumenScene`, `VirtualTracing`, `CityPlan`, `Int32`, `RendererController`, `TextureStreamer`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `SettingsTableTests`, `Float`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `BuildingAssembler`, `SoftModel`, `Rect`, `CaseIterable`, `FoliageTextures`, `EnvVariable`, `.planFrame`, `WorldTile`, `NeuralWeights`, `Interior`, `.meshes`, `.library`, `Foliage`, `BuildingPlan`, `.buildWorld`, `Int`, `DebugInfo`, `Benchmark`, `RoomType`, `VoxelLOD`, `RenderView`, `.writeDescriptors`, `.load`, `MeshBuilder`, `ComputePass`, `DatasetSpec`, `Curve`, `Furnisher`, `BuildingSpec`, `DebugPanel`, `.part`, `Lift`, `VirtualMesh`, `.draw`, `.encodeSceneUpdate`, `PlantParam`, `.simplify`, `Building`, `FoliageRuntimeTests`, `XCTestCase`, `Binding`, `ColliderGrid`, `PlantTracing`, `Float`, `Species`, `RagdollTests`, `LoadingOverlay`, `SceneSettings`, `.grow`, `RenderThread`, `SIMD3`, `.commit`, `Double`, `Float`, `.key`, `Clip`, `PlantEditorPanel`, `Row`, `LotRef`, `PressButton`, `WallGrid`, `BuildingEditorPanel`, `RasterScene`, `VoxelGrids`, `.encoder`, `CharacterLibrary`, `LightKind`, `WindFrame`, `.capture`, `.addRagdoll`?**
  _High betweenness centrality (0.122) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `translate`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `GPUTypes.swift`, `GeneratedCache`, `.write`, `SceneBuffers`, `View`, `VirtualGeometry`, `SceneKind`, `MuscleAtlas`, `VirtualTracing`, `RendererController`, `TextureStreamer`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `SettingsTableTests`, `Capabilities`, `Upscaler`, `FluidTests`, `Rect`, `CaseIterable`, `Bool`, `FoliageTextures`, `BuildingStore`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `.meshes`, `.library`, `Foliage`, `Key`, `BuildingPlan`, `.buildWorld`, `Int`, `DebugInfo`, `PlantEditorTests`, `Kind`, `Benchmark`, `RoomType`, `.load`, `ComputePass`, `DatasetSpec`, `Curve`, `BuildingSpec`, `DebugPanel`, `.part`, `Lift`, `VirtualMesh`, `.add`, `FBXError`, `.draw`, `.encodeSceneUpdate`, `FloorPlanView`, `PlantParam`, `Modes`, `XCTestCase`, `Binding`, `Species`, `BenchmarkModesTests`, `SceneSettings`, `FBXFile`, `SIMD3`, `SettingsStore`, `.commit`, `Where things are`, `Double`, `Clip`, `Buffer`, `Row`, `LotRef`, `PressButton`, `VoxelGrids`, `.encoder`, `Tab`, `CharacterLibrary`, `PrimitiveWork`?**
  _High betweenness centrality (0.091) - this node is a cross-community bridge._
- **Are the 51 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 51 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Batch 6: load time` and `Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1772 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.041731947016094575 - nodes in this community are weakly interconnected._