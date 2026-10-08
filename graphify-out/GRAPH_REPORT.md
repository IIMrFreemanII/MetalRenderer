# Graph Report - init-branch-7e8495  (2026-10-08)

## Corpus Check
- 266 files · ~1,310,320 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 7677 nodes · 23825 edges · 262 communities (240 shown, 22 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3479 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `80091e2a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Codable
- Lights.metal
- traceKernel
- PlantCatalog
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- LayerSurface
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- XCTestCase
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- float4x4
- Int
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- .init
- regirBuildKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- Mesh
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- VirtualGeometry
- LumenGlobalSDF
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- Types.metal
- Surface.metal
- VGBlas
- MeshData
- Direct Rendering Stress Test 32
- MeshSDF
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- CityPlan
- FluidSystem
- simd
- Metal3Pass
- FoliageVoxels
- TextureStreamer
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- VirtualBLAS
- BuildingEditorModel
- .city
- DirectLightMode
- Foliage
- FoliageTextures
- SurfaceKind
- Where things are
- Upscaler
- megaLightsSampleKernel
- FluidTests
- Crowd.metal
- PhysicsTests
- MuscleTests
- Building
- float3
- ClusterBox
- SoftModel
- float4
- Bool
- CaseIterable
- RenderSettings
- World
- BuildingCatalog
- EnvVariable
- .planFrame
- CurveEditor
- WorldTile
- geometryDebugKernel
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- Interior
- GLTFModel
- .library
- Flora
- same.sh
- Key
- baseline.sh
- .load
- .buildWorld
- SDFShape
- Raster.metal
- SettingsTableTests
- .building
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- PlantEditorTests
- Kind
- Benchmark
- RoomType
- RasterVGParams
- Map
- .write
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- Metal-only tracer: handoff to the M4 Max (2026-10-06)
- RenderView
- PlantTracing
- VSMCounters
- .load
- Hit
- QuartzCore
- SIMD3
- Pipelines
- Int32
- Curve
- .build
- Furnisher
- FloorPlan
- RendererController
- FBXFile
- TraceScene
- Intersect.metal
- AppKit
- Lift
- related.sh
- LumenCards
- RTVoxels
- .buildGallery
- VGParams
- Where new code belongs
- .add
- FBXError
- VSM.metal
- .draw
- FrameEncoder
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- SkinShell
- SDFVolume
- LoadingOverlay
- VSMParams
- FoliageRuntimeTests
- SIMD4
- RasterParams
- Role
- Clip
- physicsSubstepsKernel
- VSMInstance
- ColliderGrid
- InputHandler
- SDFBuffers
- RasterCounters
- .addHair
- LightKind
- SDFBox
- uint
- RasterInstance
- RagdollTests
- FurnitureItem
- String
- PhysicsGrab
- .stages
- LumenRadiosityParams
- Terrain
- PhysicsConstraint
- PhysicsGroup
- PhysicsFleshFibre
- PhysicsPair
- PhysicsPoseParams
- StressSceneTests
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- Hair.metal
- Contents
- PhysicsFleshHeader
- SceneShading
- SkyParams
- LumenParams
- InstanceData
- KernelVariantsTests
- RenderThread
- BuildingEditorModel.swift
- Key
- HairBSDF
- .commit
- SceneSettings
- .modelURLs
- RenderPass4
- PhysicsParams
- Double
- .origin
- Particles
- .key
- Clip
- Stage
- PressButton
- Core
- .mark
- .setFrameSize
- Row
- Op
- VirtualGeometry
- RasterScene
- VGRasterInstance
- WallGrid
- PhysicsMuscle
- Offscreen rendering in MetalRenderer
- Heavens
- .init
- .init
- vsmFragment
- PhysicsFleshPin
- Kind
- Kind
- .init

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 472 edges
2. `Scene` - 329 edges
3. `PhysicsWorld` - 275 edges
4. `Renderer` - 270 edges
5. `Kernel` - 154 edges
6. `Foliage` - 151 edges
7. `SIMD4` - 151 edges
8. `simd` - 143 edges
9. `Benchmark` - 114 edges
10. `RenderSettings` - 109 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift

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

## Communities (262 total, 22 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.03
Nodes (65): AABB, .area, .centroid, .isEmpty, .bounds, GPUEmissiveTriangle, GPUMesh, UInt64 (+57 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.11
Nodes (39): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+31 more)

### Community 3 - "Codable"
Cohesion: 0.06
Nodes (76): Bound, Codable, Equatable, Clipboard, File, BuildingStyleDef, FacadeDef, Finish (+68 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (72): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+64 more)

### Community 5 - "traceKernel"
Cohesion: 0.05
Nodes (76): 3. Occupancy and registers: the default suspect for big kernels, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+68 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.07
Nodes (21): Foliage.Phyllotaxis, FoliageTextures.Kind, PlantCatalog, .all, .count, .covers, Decoder, Encoder (+13 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.09
Nodes (18): ObservableObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key (+10 more)

### Community 11 - "LayerSurface"
Cohesion: 0.14
Nodes (16): What headless changes, and what it doesn't, FrameOutput, Headless, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize (+8 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.20
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+3 more)

### Community 14 - "HairTests"
Cohesion: 0.21
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 15 - "Metal4Frame"
Cohesion: 0.06
Nodes (32): CAMetalLayer, Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue (+24 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (15): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+7 more)

### Community 17 - "XCTestCase"
Cohesion: 0.17
Nodes (5): simd_double3x3, SDFTests, Float, SDFShape, XCTestCase

### Community 18 - "roundToHalf"
Cohesion: 0.13
Nodes (31): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+23 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (75): makeRay(), constant, device, float2, float3, float4, kernel, Light (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.44
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "float4x4"
Cohesion: 0.15
Nodes (13): float4x4, Hall, Loop, .length, Float, SIMD2, Zone, factory (+5 more)

### Community 24 - "Int"
Cohesion: 0.05
Nodes (38): Result, UnsafeRawPointer, Range, Params, RasterClusters, .drawnByCamera, .stats, .summary (+30 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.11
Nodes (18): simd_double4x4, GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount (+10 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): Settings: `SettingsTable.swift`, NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (66): To do on the M4 Max, 8. Pipelines and resources, SkyImage, Set, GPUSkyParams, done, LoadOptions, PreparedScene (+58 more)

### Community 31 - ".init"
Cohesion: 0.18
Nodes (4): Float, RasterSceneTests, Float, MeshGeometry

### Community 32 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.06
Nodes (44): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+36 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.11
Nodes (15): CryptoKit, R, GeneratedCache, Hasher, SectionFile, .array, Data, T (+7 more)

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (47): constant, device, int3, kernel, uint, physCell(), physColourPairs(), physColoursAround() (+39 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.13
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.08
Nodes (36): GIMode, lumen, pathTraced, radianceCascades, restirGI, .title, LumenTrace, sdf (+28 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.05
Nodes (43): MTLDevice, .empty, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+35 more)

### Community 45 - "View"
Cohesion: 0.08
Nodes (61): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+53 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.07
Nodes (25): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindowDelegate, BuildingEditorPanel, .isVisible, .wasVisible, Notification (+17 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 51 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, buildings, .cameraFromScene, city, cityNight, cornell, crowd (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.07
Nodes (28): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+20 more)

### Community 55 - "Color Bleeding from Walls to Objects"
Cohesion: 0.40
Nodes (6): Color Bleeding from Walls to Objects, Direct and Indirect Illumination Effects, Geometric Primitives (Cylinder, Cube, Sphere, Rectangular Blocks), Global Illumination Reference Scene, Primary Light Source, Varied Material Surfaces and Reflectivity

### Community 56 - "3D Graphics Stress Test Scene"
Cohesion: 0.33
Nodes (6): Albedo Reference Image 1.5x, Color Palette Distribution, Geometric Shapes, Rendering Validation Reference, 3D Spatial Layout, 3D Graphics Stress Test Scene

### Community 57 - "Direct Lighting Reference Render"
Cohesion: 0.40
Nodes (6): Direct Lighting, Geometric Complexity, Lighting Quality and Shadows, Material Properties and Colors, Direct Lighting Reference Render, Rendering Stress Test

### Community 58 - "Geometric Primitives Rendering Test"
Cohesion: 0.50
Nodes (5): 3D Graphics Rendering Benchmark, Color Variation for Visual Distinction, Geometric Primitives Rendering Test, Object Density and Spatial Distribution, Stress Test Visualization - Geometric Primitives

### Community 59 - "MuscleAtlas"
Cohesion: 0.06
Nodes (45): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+37 more)

### Community 60 - "Types.metal"
Cohesion: 0.06
Nodes (41): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+33 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (87): Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+79 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "MeshSDF"
Cohesion: 0.15
Nodes (12): Int8, Baked, bricks, Heightfield, .hi, MeshSDF, .bytes, .hi (+4 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.08
Nodes (21): Float, UnsafeBufferPointer, .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged, Content, MTLAccelerationStructure (+13 more)

### Community 73 - "CityPlan"
Cohesion: 0.07
Nodes (33): .name, Block, CityPlan, Edge, open, party, street, Lamp (+25 more)

### Community 74 - "FluidSystem"
Cohesion: 0.10
Nodes (19): .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem, .capacity (+11 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (18): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+10 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.47
Nodes (6): FoliageVoxels, Grid, Piece, Plant, Float, UInt32

### Community 78 - "TextureStreamer"
Cohesion: 0.07
Nodes (29): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLBuffer, MTLCommandBuffer (+21 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.20
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.09
Nodes (19): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, LoadStep (+11 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.07
Nodes (37): Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice (+29 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.07
Nodes (21): BuildingEditorHost, BuildingEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .savedDef, .workshopSettings (+13 more)

### Community 87 - ".city"
Cohesion: 0.15
Nodes (8): Block, Roadbeds, SIMD2, Data, StaticString, T, UInt, WorldTests

### Community 88 - "DirectLightMode"
Cohesion: 0.12
Nodes (13): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, DirectLightMode, auto, exact, grouped, megalights (+5 more)

### Community 89 - "Foliage"
Cohesion: 0.11
Nodes (28): Level, Mesh, Float, Bone, Card, Carve, Foliage, Graft (+20 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.08
Nodes (26): Float, MaterialDef, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete (+18 more)

### Community 92 - "Where things are"
Cohesion: 0.23
Nodes (6): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests, Void

### Community 93 - "Upscaler"
Cohesion: 0.17
Nodes (11): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLTexture, SIMD2 (+3 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.10
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (52): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+44 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.12
Nodes (9): GPUPhysicsGrab, Cloth, Set, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape (+1 more)

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (9): centre, PhysicsJoint, PhysicsJointKind, ball, hinge, Float, SDFShape, UInt32 (+1 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (47): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail, flat (+39 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (33): float3, thread, physAcross(), physAdd(), physAddFound(), physAgree(), physArea(), physBox() (+25 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (19): ArraySlice, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, Float (+11 more)

### Community 103 - "float4"
Cohesion: 0.04
Nodes (59): float4, uint4, physBetween(), physBreeze(), PhysicsCloth, grid, previous, PhysicsHairGroup (+51 more)

### Community 104 - "Bool"
Cohesion: 0.12
Nodes (16): .area, PlanDoor, PlanRoom, .area, StoreyPlanner, Float, SIMD2, SplitMix64 (+8 more)

### Community 105 - "CaseIterable"
Cohesion: 0.02
Nodes (85): CaseIterable, Tab, facade, floors, furnish, look, massing, rooms (+77 more)

### Community 106 - "RenderSettings"
Cohesion: 0.06
Nodes (38): F, base, on, RenderSettings, SettingsStore, Any, DispatchWorkItem, Control (+30 more)

### Community 107 - "World"
Cohesion: 0.14
Nodes (13): World, .anchorTile, .start, Flora, Ground, Placement, Road, SplitMix64 (+5 more)

### Community 108 - "BuildingCatalog"
Cohesion: 0.05
Nodes (40): Where things are, Encodable, JSONEncoder, P, interior, .currentOverride, .currentRef, .key (+32 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 110 - ".planFrame"
Cohesion: 0.07
Nodes (21): MetalKit, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets (+13 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (18): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.16
Nodes (16): GPUMaterial, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+8 more)

### Community 113 - "geometryDebugKernel"
Cohesion: 0.05
Nodes (85): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+77 more)

### Community 114 - "Metal"
Cohesion: 0.10
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.06
Nodes (33): physContactKick(), physContactPush(), PhysicsBody, angular, info, invInertia, position, prevPosition (+25 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.17
Nodes (13): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+5 more)

### Community 118 - "Interior"
Cohesion: 0.09
Nodes (32): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+24 more)

### Community 119 - "GLTFModel"
Cohesion: 0.20
Nodes (9): GLTFModel, .triangleCount, Light, Entry, File, PropLibrary, Float, URL (+1 more)

### Community 120 - ".library"
Cohesion: 0.10
Nodes (16): RawRepresentable, Age, mature, sapling, young, Species, .description, .hasBoughs (+8 more)

### Community 121 - "Flora"
Cohesion: 0.12
Nodes (13): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+5 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (14): CodingKey, Keys, hi, lo, Foliage.Curve, Key, crown, linear (+6 more)

### Community 125 - ".load"
Cohesion: 0.15
Nodes (14): CustomStringConvertible, Error, LoadError, unreadable, GLTFError, .description, invalid, unsupported (+6 more)

### Community 126 - ".buildWorld"
Cohesion: 0.09
Nodes (14): Darwin, Camera, .forward, .right, .up, Float, BuildingStats, Float (+6 more)

### Community 127 - "SDFShape"
Cohesion: 0.12
Nodes (21): Node, .transform, Op, intersect, subtract, union, Primitive, box (+13 more)

### Community 128 - "Raster.metal"
Cohesion: 0.17
Nodes (32): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, fragment (+24 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - ".building"
Cohesion: 0.40
Nodes (4): Float, SIMD2, Walker, WalkerTests

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.11
Nodes (9): PlantMutate, Root, SplitMix64, UInt64, Host, PlantEditorTests, Root, URL (+1 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.04
Nodes (27): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Render something: `scripts/render.sh`, 6. Math, Modes, Images, Benchmark modes: `Benchmark+Modes.swift`, Benchmark (+19 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (36): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+28 more)

### Community 138 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 139 - "Map"
Cohesion: 0.08
Nodes (28): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MTLResource, BoxData, MTLAccelerationStructure (+20 more)

### Community 140 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "liquidKernel"
Cohesion: 0.16
Nodes (18): liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device, float3 (+10 more)

### Community 144 - "Metal-only tracer: handoff to the M4 Max (2026-10-06)"
Cohesion: 0.40
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are

### Community 145 - "RenderView"
Cohesion: 0.19
Nodes (7): CALayer, NSObjectProtocol, RenderView, .acceptsFirstResponder, NSEvent, Void, UTType

### Community 146 - "PlantTracing"
Cohesion: 0.06
Nodes (32): Tests, float3x3, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart (+24 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 151 - "SIMD3"
Cohesion: 0.11
Nodes (21): OptionSet, Parts, Atmosphere, Float, .triangleCount, rotate(), Faces, MeshBuilder (+13 more)

### Community 152 - "Pipelines"
Cohesion: 0.08
Nodes (33): Where things are, ComputePass, MTLComputePipelineState, Step, FluidGPU, .summary, Steps, MTLBuffer (+25 more)

### Community 153 - "Int32"
Cohesion: 0.27
Nodes (9): Compression, FBXArrayElement, Float, Int32, LocalIds, MeshClusterizer, Float, UInt32 (+1 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - ".build"
Cohesion: 0.20
Nodes (6): UInt32, UnsafeBufferPointer, MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 156 - "Furnisher"
Cohesion: 0.17
Nodes (14): Side, Furnisher, Light, Prefer, any, away, corner, middle (+6 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (6): CGSize, FloorPlan, .height, BuildingPlanTests, Float, SIMD2

### Community 158 - "RendererController"
Cohesion: 0.04
Nodes (37): NSColor, NSRect, NSStackView, .buildingPlan, .buildingStats, .cameraPosition, .walker, Float (+29 more)

### Community 159 - "FBXFile"
Cohesion: 0.13
Nodes (19): IteratorProtocol, Sequence, simd_quatd, Children, Connection, invalid, FBXFile, .topLevel (+11 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "AppKit"
Cohesion: 0.16
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "LumenCards"
Cohesion: 0.20
Nodes (10): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+2 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (33): constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster, childGroup (+25 more)

### Community 169 - "Where new code belongs"
Cohesion: 0.07
Nodes (26): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants (+18 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - "FBXError"
Cohesion: 0.14
Nodes (16): FBXError, .description, unsupported, BlobReader, BlobWriter, CharacterLibrary, .directory, concurrently() (+8 more)

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (22): float3, Light, read, SCENE_ACCEL, texture2d, thread, uint2, write (+14 more)

### Community 173 - ".draw"
Cohesion: 0.29
Nodes (4): StyleDraw, Decoder, T, UInt64

### Community 174 - "FrameEncoder"
Cohesion: 0.05
Nodes (35): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor (+27 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.13
Nodes (22): Color, GraphicsContext, FloorPlanView, .body, .help, .picked, .status, .storeys (+14 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "PlantParam"
Cohesion: 0.21
Nodes (9): L, .body, PlantParam, .isInteger, PlantParams, Float, Root, Void (+1 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "uint"
Cohesion: 0.32
Nodes (16): constant, device, float4, kernel, uint, vertex, vsmAllocKernel(), vsmChunksKernel() (+8 more)

### Community 181 - "SkinShell"
Cohesion: 0.29
Nodes (8): .cells, SkinOptions, SkinShell, Float, MeshGeometry, SIMD2, UInt32, .edges

### Community 182 - "SDFVolume"
Cohesion: 0.27
Nodes (5): Float16, SDFVolume, .hi, Float, MeshGeometry

### Community 183 - "LoadingOverlay"
Cohesion: 0.27
Nodes (5): NSPoint, NSView, LoadingOverlay, .isEnabled, Timer

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD4"
Cohesion: 0.10
Nodes (22): GPUPhysicsShape, .worldToView, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+14 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "Clip"
Cohesion: 0.25
Nodes (6): Clip, graft, habitat, leaves, level, look

### Community 190 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.28
Nodes (8): ColliderGrid, Input, Moving, Float, SIMD2, Walker, .eyePosition, .height

### Community 193 - "InputHandler"
Cohesion: 0.24
Nodes (4): AnyObject, InputHandler, Float, SIMD2

### Community 194 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

### Community 197 - "LightKind"
Cohesion: 0.20
Nodes (10): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+2 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 200 - "RasterInstance"
Cohesion: 0.20
Nodes (10): float4, RasterInstance, corners, indices, w, x, y, RasterMesh (+2 more)

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.40
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "String"
Cohesion: 0.10
Nodes (12): MTLBlitCommandEncoder, MTLRenderPassDescriptor, CatalogRegistry, T, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder (+4 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - ".stages"
Cohesion: 0.20
Nodes (12): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLTexture (+4 more)

### Community 206 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 207 - "Terrain"
Cohesion: 0.28
Nodes (6): Float, SIMD2, UInt32, UInt64, Terrain, .cell

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

### Community 219 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 220 - "Contents"
Cohesion: 0.32
Nodes (4): Contents, MappedFile, UnsafeRawPointer, URL

### Community 221 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 222 - "SceneShading"
Cohesion: 0.12
Nodes (16): MaterialTexture, t, texture2d, texture2d_array, SceneShading, cloudShadow, emissive, feedback (+8 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 225 - "InstanceData"
Cohesion: 0.25
Nodes (8): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform

### Community 227 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 228 - "BuildingEditorModel.swift"
Cohesion: 0.33
Nodes (3): Combine, Element, Array

### Community 229 - "Key"
Cohesion: 0.39
Nodes (5): Hashable, Key, PipelineCache, .count, Value

### Community 231 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "SceneSettings"
Cohesion: 0.06
Nodes (18): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, MTLBuffer, MTLDevice, MTLTexture (+10 more)

### Community 233 - ".modelURLs"
Cohesion: 0.47
Nodes (3): NSDraggingInfo, NSDragOperation, URL

### Community 234 - "RenderPass4"
Cohesion: 0.10
Nodes (11): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, MTLResource (+3 more)

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Double"
Cohesion: 0.25
Nodes (5): Double, MTLDevice, City, Highway, Float

### Community 237 - ".origin"
Cohesion: 0.16
Nodes (7): Float, .time, Float, SIMD2, WorldPlace, .anchor, UInt64

### Community 238 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 240 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PressButton"
Cohesion: 0.22
Nodes (4): PressButton, .body, Void, SwiftUI

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 246 - "Row"
Cohesion: 0.16
Nodes (10): NSFont, Model, heading, item, Row, State, failed, running (+2 more)

### Community 247 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

### Community 248 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 249 - "RasterScene"
Cohesion: 0.15
Nodes (12): Kind, arrays, block, clusters, skip, virtual, RasterScene, .megabytes (+4 more)

### Community 250 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 251 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "Offscreen rendering in MetalRenderer"
Cohesion: 0.50
Nodes (3): Offscreen rendering in MetalRenderer, Recipes, Rules

### Community 254 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - ".init"
Cohesion: 0.50
Nodes (3): CGRect, MTLDevice, NSCoder

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, furniture, glass, solid, stair, UInt8

### Community 261 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

## Knowledge Gaps
- **1735 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1730 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2333 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **22 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Codable`, `PlantCatalog`, `.simplify`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `LightTable`, `float4x4`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `.init`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `View`, `LumenScene`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `MeshSDF`, `VirtualTracing`, `CityPlan`, `FluidSystem`, `Metal3Pass`, `FoliageVoxels`, `TextureStreamer`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `.city`, `DirectLightMode`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `FluidTests`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Bool`, `CaseIterable`, `RenderSettings`, `World`, `BuildingCatalog`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `GLTFModel`, `.library`, `Flora`, `.load`, `.buildWorld`, `SDFShape`, `SettingsTableTests`, `.building`, `TraversalStats`, `PlantEditorTests`, `Benchmark`, `RoomType`, `Map`, `.write`, `PlantTracing`, `SIMD3`, `Pipelines`, `Int32`, `Curve`, `.build`, `Furnisher`, `FloorPlan`, `RendererController`, `FBXFile`, `Lift`, `LumenCards`, `.buildGallery`, `FBXError`, `FrameEncoder`, `FloorPlanView`, `PlantParam`, `SkinShell`, `SDFVolume`, `FoliageRuntimeTests`, `SIMD4`, `Role`, `ColliderGrid`, `SDFBuffers`, `.addHair`, `LightKind`, `RagdollTests`, `FurnitureItem`, `String`, `.stages`, `Terrain`, `StressSceneTests`, `Contents`, `BuildingEditorModel.swift`, `Key`, `.commit`, `SceneSettings`, `RenderPass4`, `Double`, `.origin`, `.key`, `Row`, `VirtualGeometry`, `RasterScene`, `.init`?**
  _High betweenness centrality (0.331) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `restirGIInitialKernel`, `KernelVariantsTests`, `traceKernel`, `Where new code belongs`, `Pipelines`, `Kernel`?**
  _High betweenness centrality (0.111) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `Codable`, `PlantCatalog`, `.simplify`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `float4x4`, `Int`, `SettingsPanel`, `Renderer`, `.init`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `View`, `LumenScene`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `MeshSDF`, `VirtualTracing`, `CityPlan`, `FluidSystem`, `FoliageVoxels`, `TextureStreamer`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `.city`, `DirectLightMode`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Where things are`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `RenderSettings`, `BuildingCatalog`, `EnvVariable`, `.planFrame`, `WorldTile`, `BuildingAssembler`, `Interior`, `.library`, `Flora`, `.buildWorld`, `SDFShape`, `SettingsTableTests`, `Benchmark`, `RoomType`, `Map`, `RenderView`, `PlantTracing`, `.load`, `SIMD3`, `Pipelines`, `Int32`, `Curve`, `Furnisher`, `FloorPlan`, `RendererController`, `FBXFile`, `Lift`, `LumenCards`, `FBXError`, `.draw`, `FrameEncoder`, `PlantParam`, `LoadingOverlay`, `FoliageRuntimeTests`, `Clip`, `ColliderGrid`, `.addHair`, `LightKind`, `RagdollTests`, `String`, `RenderThread`, `Key`, `.commit`, `SceneSettings`, `.modelURLs`, `Double`, `.origin`, `.key`, `PressButton`, `Core`, `Row`, `VirtualGeometry`, `RasterScene`, `WallGrid`, `Heavens`?**
  _High betweenness centrality (0.108) - this node is a cross-community bridge._
- **Are the 50 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 50 INFERRED edges - model-reasoned connections that need verification._
- **Are the 33 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 33 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1735 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.03332275468105363 - nodes in this community are weakly interconnected._