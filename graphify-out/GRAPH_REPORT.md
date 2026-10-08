# Graph Report - MetalRenderer  (2026-10-09)

## Corpus Check
- 297 files · ~1,612,399 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 29 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 3)

## Summary
- 7999 nodes · 24890 edges · 283 communities (229 shown, 54 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3795 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `147fa3bf`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- pcgHash
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
- Float
- .meshes
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- RasterScene
- Bool
- restirTemporalKernel
- restirGIInitialKernel
- .stages
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
- AABB
- AppDelegate
- Crowd
- VirtualGeometry
- LumenGlobalSDF
- SceneKind
- 3D Geometric Test Scene
- .xyz
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Surface.metal
- VGBlas
- MeshData
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
- PhysicsWorld
- simd
- RenderPass
- RendererController
- .used
- Double
- KernelVariants
- ab.sh
- LoadActivity
- instanceRecord
- Intersect.metal
- TextureStreamer
- BuildingEditorModel
- SettingsTableTests
- Capabilities
- Foliage
- physicsSubstepsKernel
- .buildStress
- flagOn
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- Crowd.metal
- PhysicsTests
- MuscleTests
- BuildingAssembler
- float3
- ClusterBox
- SoftModel
- float4
- Rect
- CaseIterable
- SettingsTable
- FoliageTextures
- BuildingCatalog
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
- float4x4
- Tab
- Flora
- same.sh
- Key
- baseline.sh
- BuildingPlan
- SurfaceKind
- export.py
- Raster.metal
- Int
- FluidSystem
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- PlantEditorTests
- Kind
- Config
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
- .city
- Hit
- QuartzCore
- MeshBuilder
- Pipelines
- DatasetSpec
- Curve
- Post.metal
- Furnisher
- FloorPlan
- DebugPanel
- .part
- TraceScene
- Ray
- CoreGraphics
- Primitive
- related.sh
- SDFShape
- RTVoxels
- .begin
- VGParams
- GPU (Metal / MSL) practices for MetalRenderer
- .add
- FBXError
- VSM.metal
- BuildingStyleDef
- Metal3Frame
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- .addFleshCharacter
- Modes
- Slot
- VSMParams
- FoliageRuntimeTests
- Where things are
- RasterParams
- Role
- Neural.metal
- VSMInstance
- ColliderGrid
- train.py
- PlantTracing
- RasterCounters
- Map
- Float
- SDFBox
- PhysicsFleshHeader
- SceneShading
- RagdollTests
- CityTests
- Benchmark
- .floatCapture
- .clusterize
- PostParams
- Terrain
- PhysicsConstraint
- PhysicsGroup
- PhysicsFleshFibre
- PhysicsPair
- PhysicsPoseParams
- SceneBuffersTests
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- traceKernel
- FBXFile
- TextureStreamerTests
- uint
- SkyParams
- .vgdebug
- D. Structure / duplication
- LumenMeshSDF
- RenderThread
- SIMD3
- SettingsStore
- HairBSDF
- .commit
- SceneSettings
- SDFBuffers
- RenderPass4
- PhysicsParams
- Float
- World
- Float
- PipelineCache
- float4
- ShowcaseLook
- PlantEditorPanel
- lumen.py
- .building
- Buffer
- LoadingOverlay
- .record
- PressButton
- KernelVariantsTests
- Types.metal
- WallGrid
- PhysicsMuscle
- BuildingEditorPanel
- .move
- VoxelGrids
- vsmFragment
- PhysicsFleshPin
- CharacterLibrary
- Kind
- PrimitiveWork
- PhysicsGrab
- TrainingSceneTests
- Launch
- Batch 5: per-frame CPU
- WindFrame
- VirtualGeometry
- .load
- Measuring MetalRenderer
- Phyllotaxis
- .end
- Zone
- Faces
- demo-video.sh
- make-dataset.sh

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 480 edges
2. `Scene` - 337 edges
3. `Renderer` - 278 edges
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
Cohesion: 0.03
Nodes (49): Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6), GPUEmissiveTriangle, GPUMesh, meshLights, Assembly, Bone, BorrowedLight, BorrowedMesh (+41 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.06
Nodes (38): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+30 more)

### Community 3 - "RenderSettings"
Cohesion: 0.07
Nodes (56): Cover, Habitat, Ramp, TreePicker, .isEmpty, AgeRule, Ages, CountRule (+48 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (66): Pass 2: sample + trace (`megaLightsSampleKernel`), clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget() (+58 more)

### Community 5 - "pcgHash"
Cohesion: 0.07
Nodes (23): glassKernel(), glassReflection(), cosineSampleHemisphere(), laineKarrasPermutation(), makeSampler(), nestedUniformScramble(), owenSobol2(), pcgHash() (+15 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.06
Nodes (19): .hasBoughs, .isTree, .savedDef, Foliage.Phyllotaxis, FoliageTextures.Kind, PlantCatalog, .all, .count (+11 more)

### Community 7 - "common.py"
Cohesion: 0.11
Nodes (17): aces(), array_path(), clip_dirs(), display(), frames(), load(), matches(), paused() (+9 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (82): fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf(), fluidCellsClearKernel(), fluidCellSortKernel() (+74 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.07
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 10 - "PlantEditorModel"
Cohesion: 0.07
Nodes (20): Clip, graft, habitat, leaves, level, look, Clipboard, PlantEditorHost (+12 more)

### Community 11 - "LayerSurface"
Cohesion: 0.15
Nodes (8): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.14
Nodes (13): rcClearAmbientKernel(), rcEvalSH(), RCParams, grids, interval, layout, RCProbeBatch, cascades (+5 more)

### Community 13 - "FramePlan"
Cohesion: 0.13
Nodes (17): B. Remaining per-frame CPU, 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, ComputeStage, FrameEncoder, RenderAttachments, GPURasterParams (+9 more)

### Community 16 - "translate"
Cohesion: 0.14
Nodes (12): Scene kinds: `SceneKind` in `Settings.swift`, GPUMaterial, scale(), translate(), FogVolume, .gpu, LightPose, Kit (+4 more)

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
Nodes (60): distance, makeRay(), pathTraceKernel(), PathTraceParams, bounds, config, samples, PTFog (+52 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (4): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount

### Community 23 - "Float"
Cohesion: 0.25
Nodes (3): Hall, Loop, .length

### Community 24 - ".meshes"
Cohesion: 0.04
Nodes (26): Params, RasterClusters, .drawnByCamera, .stats, .summary, .data, VGView, Built (+18 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (42): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+34 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.14
Nodes (12): GPUJoint, .parent, GPUSkinVertex, Clip, .duration, .loopKeys, Level, .triangleCount (+4 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.14
Nodes (21): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams, grid, options (+13 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (140): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+132 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (7): Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (45): Batch 3: launch time, To do on the M4 Max, done, LoadOptions, PreparedScene, Renderer, .accumulating, .activeDirectMode (+37 more)

### Community 31 - "RasterScene"
Cohesion: 0.15
Nodes (4): RasterScene, .megabytes, RasterTargets, RasterSceneTests

### Community 32 - "Bool"
Cohesion: 0.13
Nodes (15): Cell, .center, .width, Opening, BuildingStyle, .isOffice, PlanShape, courtyard (+7 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.06
Nodes (33): regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup(), RegirParams (+25 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.10
Nodes (33): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+25 more)

### Community 35 - ".stages"
Cohesion: 0.16
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "GPUTypes.swift"
Cohesion: 0.09
Nodes (28): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUInstanceData, GPUJointMatrix (+20 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.10
Nodes (10): CryptoKit, GeneratedCache, Hasher, SectionFile, Stored, .array, .count, mapped (+2 more)

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (41): physCell(), physColourPairs(), physColoursAround(), physDirection(), physDistance2(), physFlat(), physHash(), physicsClearKernel() (+33 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.21
Nodes (5): Mesh, .leafTriangles, .triangles, MeshSize, MeshWriter

### Community 42 - "String"
Cohesion: 0.03
Nodes (88): .name, CatalogRegistry, Section, Frame, CityStyle, mixed, modern, office (+80 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (16): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Kind, sphere, spot (+8 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (18): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+10 more)

### Community 45 - "View"
Cohesion: 0.08
Nodes (54): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+46 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (8): Blue Hemisphere, Green Vertical Plane, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism, Yellow Cube

### Community 47 - "AABB"
Cohesion: 0.05
Nodes (24): AABB, .area, .centroid, .isEmpty, BinScratch, BVHBuilder, BVHNode, Node (+16 more)

### Community 49 - "Crowd"
Cohesion: 0.11
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.12
Nodes (12): Build, Params, VGPipelines, VirtualGeometry, .clusterCount, .groupCount, .meshCount, .pool (+4 more)

### Community 51 - "LumenGlobalSDF"
Cohesion: 0.08
Nodes (11): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes (+3 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (42): SceneKind, area, buildings, bulbRoom, .cameraFromScene, city, cityNight, cornell (+34 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.12
Nodes (6): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .right, .up, .bodies

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
Nodes (31): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+23 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (75): reflectionHitRadiance(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+67 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (19): VGBlas, attrs, pad0, pad1, pad2, triangles, tris, VGClusterView (+11 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (12): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+4 more)

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
Cohesion: 0.09
Nodes (8): .instanceAS, .virtualGeometryChanged, Content, TraceSceneArgs, VirtualTracing, .extraInstances, .pool, .summary

### Community 73 - "CityPlan"
Cohesion: 0.05
Nodes (44): .entry, .well, Core, .all, .stairPlan, Mode, backCore, frontCore (+36 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.08
Nodes (12): Int32, GPUFluidParams, GPUFluidParticle, Cloth, PhysicsWorld, .buckets, .cellSize, .kinematicRows (+4 more)

### Community 77 - "RendererController"
Cohesion: 0.10
Nodes (12): .buildingPlan, .buildingStats, .cameraPosition, .walker, DebugInfo, .plantStats, RendererController, .debugActive (+4 more)

### Community 78 - ".used"
Cohesion: 0.16
Nodes (4): SparseMapping, TextureStreamWork, TextureUpload, TileAllocator

### Community 79 - "Double"
Cohesion: 0.21
Nodes (4): Double, City, Highway, Road

### Community 80 - "KernelVariants"
Cohesion: 0.19
Nodes (6): Pipelines: `Pipelines.swift`, finish, .function, KernelVariants, .count, Key

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.14
Nodes (8): Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, LoadStep, .isCancelled

### Community 83 - "instanceRecord"
Cohesion: 0.14
Nodes (26): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+18 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.19
Nodes (15): assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true>, octDecode() (+7 more)

### Community 85 - "TextureStreamer"
Cohesion: 0.16
Nodes (8): Entry, Level, TextureStreamer, .details, .levelProgress, .placement, .summary, .textures

### Community 86 - "BuildingEditorModel"
Cohesion: 0.06
Nodes (17): BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def, .inWorkshop, .isBuiltIn, .isDirty (+9 more)

### Community 87 - "SettingsTableTests"
Cohesion: 0.13
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 88 - "Capabilities"
Cohesion: 0.21
Nodes (5): Capabilities: `Capabilities.swift`, Capabilities, .summary, CapabilitiesTests, .none

### Community 89 - "Foliage"
Cohesion: 0.06
Nodes (25): Age, mature, sapling, young, Bone, Card, Carve, Foliage (+17 more)

### Community 90 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 92 - "flagOn"
Cohesion: 0.20
Nodes (14): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), finiteSample() (+6 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (3): UpscaleInputs, Upscaler, View

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (37): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+29 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (14): Metal3Pass, .declarationScope, FluidWorld, LiquidKind, blood, honey, .look, .name (+6 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (45): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+37 more)

### Community 98 - "MuscleTests"
Cohesion: 0.10
Nodes (5): centre, MeshSimplifier, Quadric, .edges, MuscleTests

### Community 99 - "BuildingAssembler"
Cohesion: 0.07
Nodes (27): Building, BuildingAssembler, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail (+19 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (30): physAcross(), physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient(), PhysCandidate (+22 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (13): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+5 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (5): NearCache, SoftModel, .near, .radius, SoftBodyTests

### Community 103 - "float4"
Cohesion: 0.04
Nodes (57): physBetween(), physBreeze(), PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh (+49 more)

### Community 104 - "Rect"
Cohesion: 0.13
Nodes (15): Kind, door, entrance, glazed, lift, open, PlanDoor, PlanRoom (+7 more)

### Community 105 - "CaseIterable"
Cohesion: 0.03
Nodes (76): Tab, facade, floors, furnish, look, massing, rooms, site (+68 more)

### Community 106 - "SettingsTable"
Cohesion: 0.08
Nodes (23): on, .reservoirCount, Control, checkbox, custom, popup, slider, Custom (+15 more)

### Community 107 - "FoliageTextures"
Cohesion: 0.16
Nodes (10): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+2 more)

### Community 108 - "BuildingCatalog"
Cohesion: 0.07
Nodes (23): Where things are, .key, BuildingCatalog, .fingerprint, .launch, BuildingStore, .encoder, .folder (+15 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 110 - ".planFrame"
Cohesion: 0.06
Nodes (21): Denoise, Integration (follow the ReSTIR wiring; refactor-skill rules), MetalKit, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUMegaLightsParams, GPUPostParams (+13 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (10): CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey, EnvironmentValues, .editorDrag (+2 more)

### Community 112 - "WorldTile"
Cohesion: 0.12
Nodes (9): Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, WorldTile, .triangles (+1 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (33): sdfEval(), sdfJoin(), sdfMarch(), SDFNode, k, kind, material, op (+25 more)

### Community 114 - "Metal"
Cohesion: 0.09
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.06
Nodes (33): physContactKick(), physContactPush(), PhysicsBody, angular, info, invInertia, position, prevPosition (+25 more)

### Community 117 - "NeuralWeights"
Cohesion: 0.07
Nodes (17): GPUNeuralParams, Header, NeuralError, format, memory, NeuralInputs, NeuralPipelines, NeuralUpscaler (+9 more)

### Community 118 - "Interior"
Cohesion: 0.12
Nodes (13): Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder, LiftShaft, Maker (+5 more)

### Community 119 - "float4x4"
Cohesion: 0.07
Nodes (19): Batch 6: load time, Darwin, DatasetFrame, .cameraPose, Prop, GLTFModel, .triangleCount, Light (+11 more)

### Community 120 - "Tab"
Cohesion: 0.29
Nodes (7): Tab, ages, boughs, habitat, leaves, look, stems

### Community 121 - "Flora"
Cohesion: 0.14
Nodes (9): Flora, .name, Placed, assembly, flat, Prepared, boxes, flat (+1 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (11): Keys, hi, lo, Foliage.Curve, Key, crown, linear, points (+3 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.20
Nodes (6): DemoWalk, Point, CameraTrack, .duration, Key, BuildingPlan

### Community 126 - "SurfaceKind"
Cohesion: 0.06
Nodes (21): MaterialMeshes, SurfaceMaterial, .uvScale, Maps, ProceduralTextures, SurfaceKind, asphalt, brick (+13 more)

### Community 127 - "export.py"
Cohesion: 0.12
Nodes (8): golden(), main(), write_nnw(), conv(), DenoisingUpscaler, prepare(), to_linear(), warp()

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (27): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+19 more)

### Community 129 - "Int"
Cohesion: 0.07
Nodes (12): Card, GPULumenCard, LumenCards, .megabytes, Int, .envText, BuddyAllocator, Group (+4 more)

### Community 130 - "FluidSystem"
Cohesion: 0.19
Nodes (11): .surfaceCapacity, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims, .domain, .mass (+3 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.09
Nodes (30): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+22 more)

### Community 132 - "TraversalStats"
Cohesion: 0.29
Nodes (5): 9. Shader helpers: use them, don't copy, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (40): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+32 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (34): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+26 more)

### Community 138 - "RasterVGParams"
Cohesion: 0.20
Nodes (10): RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad, requestCapacity (+2 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.17
Nodes (4): .megabytes, Entry, VoxelLOD, .megabytes

### Community 140 - "BlueNoise"
Cohesion: 0.13
Nodes (5): BlueNoise, .cacheURL, SplitMix64, CacheFile, CacheTests

### Community 141 - "FluidSurface.metal"
Cohesion: 0.37
Nodes (12): fluidCorner(), fluidSurfaceBlurKernel(), fluidSurfaceCell(), fluidSurfaceClearKernel(), fluidSurfaceCoords(), fluidSurfaceCountKernel(), fluidSurfaceEdges(), fluidSurfaceNode() (+4 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.11
Nodes (24): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, RasterMeshVertex, rasterVGCutKernel(), rasterVGMeshArgsKernel(), rasterVGRetestKernel(), rvgDraw() (+16 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (6): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial()

### Community 144 - "MEMORY.md"
Cohesion: 0.15
Nodes (5): Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (3): InputHandler, RenderView, .acceptsFirstResponder

### Community 146 - ".writeDescriptors"
Cohesion: 0.20
Nodes (7): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Tests, Timings, What could not be run, Wind

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - ".city"
Cohesion: 0.21
Nodes (3): .time, Block, Roadbeds

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (10): committedCurve(), Hit, barycentrics, cluster, hit, instance, part, primitive (+2 more)

### Community 150 - "QuartzCore"
Cohesion: 0.09
Nodes (7): AppKit, Combine, MetalFX, QuartzCore, Array, Headless, UniformTypeIdentifiers

### Community 151 - "MeshBuilder"
Cohesion: 0.17
Nodes (6): .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount

### Community 152 - "Pipelines"
Cohesion: 0.08
Nodes (20): ComputePass, Step, FluidGPU, .summary, Steps, System, Group, PhysicsGPU (+12 more)

### Community 153 - "DatasetSpec"
Cohesion: 0.10
Nodes (10): CameraDrift, DatasetClip, DatasetSpec, .clipList, 1. Make the dataset, 2. Train, 3. Use it in the app, Our own denoising upscaler (+2 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (14): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+6 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (11): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+3 more)

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (10): Furnisher, FurnishPalette, Light, Prefer, any, away, corner, middle (+2 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (3): FloorPlan, .height, BuildingPlanTests

### Community 158 - "DebugPanel"
Cohesion: 0.09
Nodes (6): DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, cpu

### Community 159 - ".part"
Cohesion: 0.22
Nodes (6): CharacterImporter, concurrently(), Skeleton, .bindPositions, .bindRotations, SourceClip

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "Ray"
Cohesion: 0.19
Nodes (19): anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery(), intersectAny() (+11 more)

### Community 163 - "Primitive"
Cohesion: 0.15
Nodes (13): Node, .transform, Op, intersect, subtract, union, Primitive, box (+5 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "SDFShape"
Cohesion: 0.30
Nodes (5): SDFShape, .gpuNodes, .materialCount, .stepScale, SurfaceNets

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - ".begin"
Cohesion: 0.30
Nodes (4): Snapshot, .isIdle, Stream, LoadActivityTests

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (28): vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere (+20 more)

### Community 169 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.06
Nodes (30): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, 10. GPU tools, 1. Frame structure and submission (+22 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (3): Hash, .value, PlantGoldenTests

### Community 171 - "FBXError"
Cohesion: 0.19
Nodes (7): FBXError, .description, BlobReader, BlobWriter, Mapping, controlPoint, polygonVertex

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (14): shadowVisible(), vsmBoxPages(), vsmClip(), vsmClipLocal(), vsmCullKernel(), vsmDebugKernel(), vsmEntry(), vsmFootprint() (+6 more)

### Community 173 - "BuildingStyleDef"
Cohesion: 0.07
Nodes (23): Clip, facade, furnish, look, massing, plan, rooms, Clipboard (+15 more)

### Community 174 - "Metal3Frame"
Cohesion: 0.07
Nodes (7): Metal3Frame, PrimitiveRefit, TLASUpdate, .descriptor, GPUProfiler, .descriptor4, .passProfilingSupported

### Community 175 - "FloorPlanView"
Cohesion: 0.17
Nodes (12): FloorPlanView, .body, .help, .picked, .status, .storeys, .toolbar, Mapping (+4 more)

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

### Community 181 - ".addFleshCharacter"
Cohesion: 0.09
Nodes (12): GPUSoftVertex, Flesh, FleshOptions, MuscleSpec, Side, back, front, out (+4 more)

### Community 182 - "Modes"
Cohesion: 0.12
Nodes (17): Batch 1: shader file split, Batch 2: shader duplication, Batch 4: small GPU items, Batch 7: housekeeping, C. GPU, Context, MetalGI: the rest of the audit backlog, in seven batches, Not in this plan (+9 more)

### Community 183 - "Slot"
Cohesion: 0.10
Nodes (19): Slot, accent, blind, dark, floor, frame, glass, interior (+11 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "Where things are"
Cohesion: 0.23
Nodes (5): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.10
Nodes (26): FurnitureItem, .collisionBoxes, Role, book0, book1, book2, book3, carton (+18 more)

### Community 190 - "Neural.metal"
Cohesion: 0.18
Nodes (10): neuralConvKernel(), neuralFinishKernel(), NeuralParams, channels, frame, shape, size, neuralPoolKernel() (+2 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.25
Nodes (7): .cells, ColliderGrid, Input, Moving, Walker, .eyePosition, .height

### Community 193 - "train.py"
Cohesion: 0.13
Nodes (6): Sequences, display(), loss_fn(), step(), masked_l1(), run_sequence()

### Community 194 - "PlantTracing"
Cohesion: 0.13
Nodes (6): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 196 - "Map"
Cohesion: 0.14
Nodes (11): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, FluidSurface, dims, field (+3 more)

### Community 197 - "Float"
Cohesion: 0.23
Nodes (4): PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 200 - "SceneShading"
Cohesion: 0.15
Nodes (12): SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky, skyParams (+4 more)

### Community 203 - "Benchmark"
Cohesion: 0.09
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 204 - ".floatCapture"
Cohesion: 0.12
Nodes (3): DatasetCapture, inputs, reference

### Community 206 - "PostParams"
Cohesion: 0.17
Nodes (11): Material, albedo, emission, params, textures, PostParams, bloom, finish (+3 more)

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "PhysicsFleshFibre"
Cohesion: 0.16
Nodes (11): PhysicsFleshFibre, compliance, g, muscle, pad0, pad1, PhysicsHairVertex, position (+3 more)

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "traceKernel"
Cohesion: 0.10
Nodes (34): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+26 more)

### Community 220 - "FBXFile"
Cohesion: 0.12
Nodes (13): Compression, Children, Connection, Contents, FBXArrayElement, invalid, unsupported, FBXFile (+5 more)

### Community 222 - "uint"
Cohesion: 0.29
Nodes (10): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+2 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - ".vgdebug"
Cohesion: 0.22
Nodes (6): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are

### Community 225 - "D. Structure / duplication"
Cohesion: 0.09
Nodes (15): Backlog: the rest of the audit, Context, D. Structure / duplication, E. Load time, Earlier plan (done on 2026-10-03): safety fixes + market CPU wins, F. Housekeeping, Step 0: baseline and a CPU meter, Step 1: safety (A-items), no image change except A3 (+7 more)

### Community 226 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (13): LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo, plant (+5 more)

### Community 228 - "SIMD3"
Cohesion: 0.08
Nodes (19): GPUHairVertex, GPUPhysicsShape, .worldToView, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind (+11 more)

### Community 232 - "SceneSettings"
Cohesion: 0.07
Nodes (11): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, SceneSettings, BuildingWorkshopTests, ForestTests (+3 more)

### Community 233 - "SDFBuffers"
Cohesion: 0.24
Nodes (3): BoxData, SDFBuffers, .buffers

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Float"
Cohesion: 0.15
Nodes (7): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation, Placement

### Community 237 - "World"
Cohesion: 0.16
Nodes (7): World, .anchorTile, .start, WorldPlace, .anchor, Ground, .treeCell

### Community 238 - "Float"
Cohesion: 0.19
Nodes (4): Event, callLift, flashlight, lights

### Community 239 - "PipelineCache"
Cohesion: 0.20
Nodes (3): PipelineCache, .count, PipelineCacheTests

### Community 240 - "float4"
Cohesion: 0.18
Nodes (10): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+2 more)

### Community 241 - "ShowcaseLook"
Cohesion: 0.08
Nodes (15): Particles, bubbles, dust, embers, none, runes, ShowcaseLook, Stage (+7 more)

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (3): PlantEditorPanel, .isVisible, .wasVisible

### Community 245 - "Buffer"
Cohesion: 0.14
Nodes (4): Buffer, mappings, metal3, metal4

### Community 246 - "LoadingOverlay"
Cohesion: 0.10
Nodes (10): LoadingOverlay, .isEnabled, Model, heading, item, Row, State, failed (+2 more)

### Community 247 - ".record"
Cohesion: 0.20
Nodes (7): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual

### Community 248 - "PressButton"
Cohesion: 0.22
Nodes (3): PressButton, .body, SwiftUI

### Community 249 - "KernelVariantsTests"
Cohesion: 0.22
Nodes (3): GPURestirGIParams, .initialPassFlags, KernelVariantsTests

### Community 250 - "Types.metal"
Cohesion: 0.22
Nodes (7): MaterialTexture, t, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 251 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "BuildingEditorPanel"
Cohesion: 0.20
Nodes (3): BuildingEditorPanel, .isVisible, .wasVisible

### Community 255 - "VoxelGrids"
Cohesion: 0.18
Nodes (8): FoliageVoxels, Grid, Piece, Plant, BoxData, VoxelGrids, .buffers, .megabytes

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 259 - "CharacterLibrary"
Cohesion: 0.28
Nodes (3): CharacterLibrary, .directory, FBXTests

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (5): Kind, furniture, glass, solid, stair

### Community 261 - "PrimitiveWork"
Cohesion: 0.20
Nodes (5): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, PrimitiveWork, .encoderCount

### Community 262 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 266 - "WindFrame"
Cohesion: 0.15
Nodes (5): PlantKey, WindFrame, .plantKey, .poseKey, PlantTracingTests

### Community 268 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 270 - "Measuring MetalRenderer"
Cohesion: 0.33
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 272 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 275 - "Zone"
Cohesion: 0.40
Nodes (5): Zone, factory, garage, office, warehouse

## Knowledge Gaps
- **1774 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1769 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2433 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **54 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `Float`, `.meshes`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `RasterScene`, `Bool`, `.stages`, `GPUTypes.swift`, `GeneratedCache`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `View`, `AABB`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `.xyz`, `MuscleAtlas`, `LumenScene`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `RenderPass`, `RendererController`, `.used`, `Double`, `KernelVariants`, `LoadActivity`, `TextureStreamer`, `BuildingEditorModel`, `SettingsTableTests`, `Foliage`, `.buildStress`, `Upscaler`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `BuildingAssembler`, `SoftModel`, `Rect`, `CaseIterable`, `SettingsTable`, `FoliageTextures`, `BuildingCatalog`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `float4x4`, `Flora`, `BuildingPlan`, `SurfaceKind`, `FluidSystem`, `TraversalStats`, `Config`, `RoomType`, `VoxelLOD`, `BlueNoise`, `.writeDescriptors`, `.city`, `QuartzCore`, `MeshBuilder`, `Pipelines`, `DatasetSpec`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `.part`, `Primitive`, `SDFShape`, `.begin`, `FBXError`, `BuildingStyleDef`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `.addFleshCharacter`, `Modes`, `Slot`, `FoliageRuntimeTests`, `Role`, `.init`, `ColliderGrid`, `PlantTracing`, `Float`, `RagdollTests`, `CityTests`, `Benchmark`, `.floatCapture`, `.clusterize`, `Terrain`, `SceneBuffersTests`, `FBXFile`, `TextureStreamerTests`, `D. Structure / duplication`, `SIMD3`, `.commit`, `SceneSettings`, `SDFBuffers`, `RenderPass4`, `World`, `Float`, `PipelineCache`, `.building`, `Buffer`, `LoadingOverlay`, `.record`, `.move`, `.encoder`, `PrimitiveWork`, `TrainingSceneTests`, `Batch 5: per-frame CPU`, `WindFrame`, `VirtualGeometry`, `Phyllotaxis`, `Zone`, `.setBytes`, `Faces`?**
  _High betweenness centrality (0.317) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `Float`, `.meshes`, `SettingsPanel`, `Renderer`, `RasterScene`, `GPUTypes.swift`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `View`, `AABB`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `.xyz`, `LumenScene`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `RendererController`, `Double`, `KernelVariants`, `LoadActivity`, `TextureStreamer`, `BuildingEditorModel`, `SettingsTableTests`, `Foliage`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `BuildingAssembler`, `SoftModel`, `Rect`, `SettingsTable`, `FoliageTextures`, `BuildingCatalog`, `EnvVariable`, `.planFrame`, `WorldTile`, `NeuralWeights`, `Interior`, `float4x4`, `Flora`, `BuildingPlan`, `SurfaceKind`, `Int`, `Config`, `RoomType`, `VoxelLOD`, `RenderView`, `.writeDescriptors`, `MeshBuilder`, `Pipelines`, `DatasetSpec`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `.part`, `SDFShape`, `.begin`, `BuildingStyleDef`, `Metal3Frame`, `PlantParam`, `.addFleshCharacter`, `Slot`, `FoliageRuntimeTests`, `Where things are`, `ColliderGrid`, `PlantTracing`, `Float`, `RagdollTests`, `CityTests`, `Benchmark`, `.clusterize`, `SceneBuffersTests`, `TextureStreamerTests`, `D. Structure / duplication`, `RenderThread`, `.commit`, `SceneSettings`, `Float`, `Float`, `PipelineCache`, `PlantEditorPanel`, `LoadingOverlay`, `.record`, `PressButton`, `WallGrid`, `BuildingEditorPanel`, `VoxelGrids`, `.encoder`, `CharacterLibrary`, `WindFrame`, `VirtualGeometry`, `.capture`?**
  _High betweenness centrality (0.124) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `translate`, `.meshes`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Bool`, `GeneratedCache`, `SceneBuffers`, `View`, `AABB`, `VirtualGeometry`, `SceneKind`, `MuscleAtlas`, `VirtualTracing`, `CityPlan`, `RendererController`, `Double`, `KernelVariants`, `LoadActivity`, `TextureStreamer`, `BuildingEditorModel`, `SettingsTableTests`, `Capabilities`, `Foliage`, `Upscaler`, `Metal3Pass`, `Rect`, `CaseIterable`, `SettingsTable`, `FoliageTextures`, `BuildingCatalog`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `float4x4`, `Tab`, `Flora`, `Key`, `BuildingPlan`, `SurfaceKind`, `Int`, `TraversalStats`, `PlantEditorTests`, `Kind`, `Config`, `RoomType`, `BlueNoise`, `.city`, `Pipelines`, `DatasetSpec`, `Curve`, `FloorPlan`, `DebugPanel`, `.part`, `.begin`, `.add`, `FBXError`, `BuildingStyleDef`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `.addFleshCharacter`, `Modes`, `Where things are`, `Benchmark`, `SceneBuffersTests`, `FBXFile`, `D. Structure / duplication`, `SIMD3`, `SettingsStore`, `.commit`, `SceneSettings`, `Float`, `World`, `ShowcaseLook`, `Buffer`, `LoadingOverlay`, `PressButton`, `KernelVariantsTests`, `VoxelGrids`, `.encoder`, `PrimitiveWork`, `Launch`?**
  _High betweenness centrality (0.090) - this node is a cross-community bridge._
- **Are the 51 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 51 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Batch 6: load time` and `Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1774 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.0345855694692904 - nodes in this community are weakly interconnected._