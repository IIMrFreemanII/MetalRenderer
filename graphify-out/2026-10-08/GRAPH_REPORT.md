# Graph Report - init-branch-7e8495  (2026-10-08)

## Corpus Check
- 266 files · ~1,307,779 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 7668 nodes · 23758 edges · 268 communities (249 shown, 19 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3447 edges (avg confidence: 0.84)
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
- PlantStore
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- RenderView
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- SDFVolume
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- .update
- Int
- LightSampling.metal
- SkinnedCharacter
- flagOn
- Kernel
- SettingsPanel
- Renderer
- SceneSettings
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
- XCTestCase
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- .part
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- .xyz
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- reflectionKernel
- VGBlas
- MeshData
- Direct Rendering Stress Test 32
- .build
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
- RenderPass
- VoxelGrids
- TextureStreamer
- AABB
- KernelVariants
- ab.sh
- LoadActivity
- lumenTraceKernel
- Ray
- .meshes
- BuildingEditorModel
- .city
- Capabilities
- Float
- FoliageTextures
- SurfaceKind
- Where things are
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- Crowd.metal
- PhysicsWorld
- MuscleTests
- BuildingSpec
- float3
- ClusterBox
- SoftModel
- float4
- Bool
- CaseIterable
- SettingsTable
- Config
- BuildingStyleDef
- EnvVariable
- .planFrame
- CurveEditor
- WorldTile
- SDFNode
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
- PlantTracing
- .buildWorld
- SDFShape
- Raster.metal
- RenderSettings
- Building
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- PlantEditorTests
- Kind
- Benchmark
- RoomType
- Images
- VoxelLOD
- .write
- FluidSurface.metal
- RasterClusters.metal
- Shaders.metal
- .env
- .createShadingResources
- .writeDescriptors
- VSMCounters
- Foliage
- Hit
- QuartzCore
- MeshBuilder
- Pipelines
- Habitat
- Curve
- MeshSDFBuilderTests
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
- Post.metal
- VGParams
- Measuring MetalRenderer
- .add
- FBXError
- VSM.metal
- Float
- GPUProfiler
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- PlantSpecies.swift
- TextureStreamWork
- Map
- LoadingOverlay
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- Role
- Clip
- physicsSubstepsKernel
- VSMInstance
- ColliderGrid
- BuildingEditorTests
- SkyImage
- RasterCounters
- .begin
- Backend
- SDFBox
- uint
- WindFrame
- RagdollTests
- FurnitureItem
- String
- PhysicsGrab
- .stages
- Buffer
- Terrain
- PhysicsConstraint
- PhysicsGroup
- PhysicsFleshFibre
- PhysicsPair
- PhysicsPoseParams
- BuildingEditorPanel
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- Hair.metal
- .capture
- PhysicsFleshHeader
- SceneShading
- SkyParams
- .updatePrimitives
- .encoder
- PlantEditorPanel
- RenderThread
- PostParams
- Key
- HairBSDF
- .commit
- .workshop
- ProceduralTextures
- RenderPass4
- PhysicsParams
- Double
- WorldPlace
- float4
- TLASUpdate
- Clip
- CameraTrack
- PressButton
- Core
- .mark
- .useResource
- Model
- Op
- DebugInfo
- RasterScene
- Tab
- WallGrid
- PhysicsMuscle
- Types.metal
- Heavens
- Heightfield
- Tab
- .generate
- PhysicsFleshPin
- Section
- Kind
- Kind
- Liquids
- .setTexture
- .setBytes
- .init
- .worldView
- .setComputePipelineState

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 469 edges
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
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift

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

## Communities (268 total, 19 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (54): GPUEmissiveTriangle, meshLights, Assembly, Bone, BorrowedLight, BorrowedMesh, float4x4, CityLight (+46 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.11
Nodes (37): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+29 more)

### Community 3 - "Codable"
Cohesion: 0.09
Nodes (59): Codable, Equatable, FacadeDef, InteriorDef, MassingDef, Programme, Proportions, Span (+51 more)

### Community 4 - "Lights.metal"
Cohesion: 0.08
Nodes (66): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+58 more)

### Community 5 - "traceKernel"
Cohesion: 0.10
Nodes (46): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), laineKarrasPermutation(), luminance(), makeSampler() (+38 more)

### Community 6 - "PlantStore"
Cohesion: 0.17
Nodes (6): File, Foliage.SpeciesDef, PlantStore, .folder, Data, URL

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
Cohesion: 0.08
Nodes (26): AnyObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key (+18 more)

### Community 11 - "RenderView"
Cohesion: 0.05
Nodes (31): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, FrameOutput, Headless, LayerSurface, .backingScale (+23 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.18
Nodes (13): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+5 more)

### Community 14 - "HairTests"
Cohesion: 0.13
Nodes (13): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64 (+5 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.13
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.12
Nodes (28): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, GPUMaterial, Camera, .forward, .right, .up, rotate() (+20 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

### Community 18 - "roundToHalf"
Cohesion: 0.14
Nodes (30): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, atrousKernel() (+22 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (76): intersectClosest(), makeRay(), constant, device, float2, float3, float4, kernel (+68 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - ".update"
Cohesion: 0.17
Nodes (7): MTLRegion, MTLSparseTextureMappingMode, mappings, SparseMapping, UInt32, UInt64, TileAllocator

### Community 24 - "Int"
Cohesion: 0.03
Nodes (71): Result, Float, UnsafeBufferPointer, Params, RasterClusters, .drawnByCamera, .stats, .summary (+63 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (16): GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount, SkinnedCharacter (+8 more)

### Community 27 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.09
Nodes (23): NSControl, NSGridView, NSObject, SkyMode, atmosphere, constant, image, .title (+15 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (55): To do on the M4 Max, 8. Pipelines and resources, LoadOptions, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode (+47 more)

### Community 31 - "SceneSettings"
Cohesion: 0.08
Nodes (12): made, SceneSettings, SIMD2, RasterSceneTests, Float, MeshGeometry, SceneBuffersTests, Float (+4 more)

### Community 32 - "regirBuildKernel"
Cohesion: 0.11
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
Cohesion: 0.10
Nodes (33): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+25 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.09
Nodes (19): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array (+11 more)

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (47): constant, device, int3, kernel, uint, physCell(), physColourPairs(), physColoursAround() (+39 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.14
Nodes (19): Card, Plant, Skeleton, LeafAnchor, LeafShape, blade, kite, needle (+11 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (67): DirectLightMode, auto, exact, grouped, megalights, restir, .title, GIMode (+59 more)

### Community 43 - "XCTestCase"
Cohesion: 0.05
Nodes (36): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+28 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (35): MTLDevice, .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description (+27 more)

### Community 45 - "View"
Cohesion: 0.08
Nodes (56): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+48 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.10
Nodes (15): GPUMesh, UInt64, GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes (+7 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, NSWindow, UndoManager, URL (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - ".part"
Cohesion: 0.19
Nodes (12): simd_double4x4, simd_quatd, StaticString, T, CharacterImporter, concurrently(), Part, Skeleton (+4 more)

### Community 51 - "DebugPanel"
Cohesion: 0.14
Nodes (8): DebugPanel, .wasVisible, CFTimeInterval, Notification, NSPanel, NSTextField, NSWindow, Void

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (42): SceneKind, area, buildings, .cameraFromScene, city, cityNight, cornell, crowd (+34 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.10
Nodes (11): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .cellSize, Float, SIMD8, UInt32, UInt64 (+3 more)

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
Cohesion: 0.07
Nodes (40): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+32 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.04
Nodes (106): Material, ggxFromDirection(), lightSpecular(), constant, device, float3, kernel, read (+98 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.23
Nodes (9): Int8, MeshSDF, .bytes, .hi, .storedBricks, MeshSDFBuilder, Float, UInt32 (+1 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (17): .instanceAS, .virtualGeometryChanged, MTLResource, Content, MTLAccelerationStructure, MTLBuffer, UInt32, TraceSceneArgs (+9 more)

### Community 73 - "CityPlan"
Cohesion: 0.07
Nodes (32): .name, Block, CityPlan, Edge, open, party, street, Lamp (+24 more)

### Community 74 - "Int32"
Cohesion: 0.08
Nodes (25): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, LocalIds (+17 more)

### Community 76 - "RenderPass"
Cohesion: 0.08
Nodes (10): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, MTLResource, MTLResourceUsage (+2 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, UInt32, MTLResource, BoxData (+9 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.14
Nodes (17): Entry, Level, Data, MTLCommandQueue, MTLDevice, MTLHeap, MTLPixelFormat, MTLSize (+9 more)

### Community 79 - "AABB"
Cohesion: 0.07
Nodes (28): AABB, .area, .centroid, .isEmpty, BinScratch, BVHBuilder, BVHNode, Node (+20 more)

### Community 80 - "KernelVariants"
Cohesion: 0.25
Nodes (14): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+6 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.14
Nodes (11): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, LoadStep (+3 more)

### Community 83 - "lumenTraceKernel"
Cohesion: 0.05
Nodes (89): int4, distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams (+81 more)

### Community 84 - "Ray"
Cohesion: 0.22
Nodes (18): geometry_type, anyHit(), assumeCurves(), boxCandidate(), closestDistance(), closestHit(), countedQuery(), intersectDistance() (+10 more)

### Community 85 - ".meshes"
Cohesion: 0.06
Nodes (37): Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice (+29 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.06
Nodes (28): Encodable, ObservableObject, BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def, .inWorkshop (+20 more)

### Community 87 - ".city"
Cohesion: 0.17
Nodes (7): Block, Road, Roadbeds, SIMD2, Data, T, WorldTests

### Community 88 - "Capabilities"
Cohesion: 0.21
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.16
Nodes (14): Level, Float, Card, Carve, Graft, Grower, LeafRecipe, Level (+6 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.11
Nodes (16): Float, MaterialDef, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+8 more)

### Community 92 - "Where things are"
Cohesion: 0.20
Nodes (6): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests, Void

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (22): Metal3Pass, .declarationScope, AnyObject, MTLComputeCommandEncoder, FluidWorld, LiquidKind, blood, honey (+14 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (52): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+44 more)

### Community 97 - "PhysicsWorld"
Cohesion: 0.06
Nodes (28): ArraySlice, GPUPhysicsGrab, GPUPhysicsParticle, GPUSoftVertex, Cloth, PhysicsWorld, .buckets, .kinematicRows (+20 more)

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (13): centre, PhysicsJoint, PhysicsJointKind, ball, hinge, Float, SDFShape, UInt32 (+5 more)

### Community 99 - "BuildingSpec"
Cohesion: 0.10
Nodes (21): BuildingSpec, .style, BuildingTier, .top, Detail, flat, full, Footprint (+13 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (33): float3, thread, physAcross(), physAdd(), physAddFound(), physAgree(), physArea(), physBox() (+25 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.07
Nodes (32): .cells, Flesh, FleshOptions, MuscleSpec, Side, back, front, out (+24 more)

### Community 103 - "float4"
Cohesion: 0.04
Nodes (59): float4, uint4, physBetween(), physBreeze(), PhysicsCloth, grid, previous, PhysicsHairGroup (+51 more)

### Community 104 - "Bool"
Cohesion: 0.13
Nodes (16): PlanDoor, PlanRoom, .area, StoreyPlanner, .programme, Float, SIMD2, SplitMix64 (+8 more)

### Community 105 - "CaseIterable"
Cohesion: 0.04
Nodes (62): CaseIterable, Scope, all, floor, upper, Tool, door, look (+54 more)

### Community 106 - "SettingsTable"
Cohesion: 0.08
Nodes (28): Bound, F, on, .reservoirCount, Control, checkbox, custom, popup (+20 more)

### Community 107 - "Config"
Cohesion: 0.11
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 108 - "BuildingStyleDef"
Cohesion: 0.08
Nodes (27): Where things are, JSONEncoder, P, BuildingMutate, BuildingParams, D, UInt64, WritableKeyPath (+19 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (28): EnvVariable, api, denoise, direct, fog, fogSet, gi, .index (+20 more)

### Community 110 - ".planFrame"
Cohesion: 0.08
Nodes (18): MetalKit, GPUPostParams, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets, LiquidTargets, MegaLightsTargets (+10 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (18): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.12
Nodes (17): Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data, Float (+9 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.11
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.06
Nodes (33): physContactKick(), physContactPush(), PhysicsBody, angular, info, invInertia, position, prevPosition (+25 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.17
Nodes (13): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+5 more)

### Community 118 - "Interior"
Cohesion: 0.14
Nodes (20): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+12 more)

### Community 119 - "GLTFModel"
Cohesion: 0.20
Nodes (12): GLTFModel, .triangleCount, Light, Material, Mesh, SIMD2, TextureRef, Entry (+4 more)

### Community 120 - ".library"
Cohesion: 0.11
Nodes (18): CustomStringConvertible, Mesh, RawRepresentable, Age, mature, sapling, young, Bone (+10 more)

### Community 121 - "Flora"
Cohesion: 0.11
Nodes (12): Flora, .name, Placed, assembly, flat, Prepared, boxes, flat (+4 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (14): CodingKey, Keys, hi, lo, Foliage.Curve, Key, crown, linear (+6 more)

### Community 125 - "PlantTracing"
Cohesion: 0.14
Nodes (17): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+9 more)

### Community 126 - ".buildWorld"
Cohesion: 0.11
Nodes (13): SurfaceMaterial, .uvScale, Prop, Data, BuildingStats, Float, WalkArea, BuildingKit (+5 more)

### Community 127 - "SDFShape"
Cohesion: 0.06
Nodes (40): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+32 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (42): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+34 more)

### Community 129 - "RenderSettings"
Cohesion: 0.07
Nodes (16): Settings: `SettingsTable.swift`, The pass, The pass after a feature, The report and the commit message, What stays fixed, What to look for, base, RenderSettings (+8 more)

### Community 130 - "Building"
Cohesion: 0.07
Nodes (30): Building, BuildingGenerator, Module, Slot, accent, blind, dark, floor (+22 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.09
Nodes (47): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+39 more)

### Community 132 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.20
Nodes (5): Host, PlantEditorTests, Root, URL, Void

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - "RoomType"
Cohesion: 0.07
Nodes (29): RoomType, backroom, bath, bedroom, corridor, dining, entrance, hall (+21 more)

### Community 138 - "Images"
Cohesion: 0.18
Nodes (3): 6. Math, Modes, Images

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): .megabytes, Entry, Float, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.08
Nodes (44): RasterClusterMeshOut, constant, device, float4, kernel, read, texture2d, thread (+36 more)

### Community 143 - "Shaders.metal"
Cohesion: 0.08
Nodes (34): Where things are, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+26 more)

### Community 144 - ".env"
Cohesion: 0.12
Nodes (11): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are, Offscreen rendering in MetalRenderer, Recipes (+3 more)

### Community 145 - ".createShadingResources"
Cohesion: 0.12
Nodes (14): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Things that are not structures yet, Where new code belongs (+6 more)

### Community 146 - ".writeDescriptors"
Cohesion: 0.17
Nodes (8): Tests, float3x3, Float, UInt32, Wind, PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Foliage"
Cohesion: 0.10
Nodes (13): Foliage, Phyllotaxis, distichous, spiral, whorled, PlantMutate, Root, SplitMix64 (+5 more)

### Community 149 - "Hit"
Cohesion: 0.15
Nodes (13): 7. Acceleration structures and ray tracing, countedHit(), Hit, barycentrics, cluster, hit, instance, part (+5 more)

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (5): Combine, Element, MetalFX, QuartzCore, Array

### Community 151 - "MeshBuilder"
Cohesion: 0.08
Nodes (24): OptionSet, Parts, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+16 more)

### Community 152 - "Pipelines"
Cohesion: 0.06
Nodes (41): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, ComputePass, FrameEncoder, PrimitiveRefit, PrimitiveWork, .encoderCount, RenderAttachments, MTLBarrierScope (+33 more)

### Community 153 - "Habitat"
Cohesion: 0.26
Nodes (9): Cover, Habitat, Ramp, Float, SIMD2, UInt32, UInt64, TreePicker (+1 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "MeshSDFBuilderTests"
Cohesion: 0.21
Nodes (4): MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (16): Side, Furnisher, FurnishPalette, Light, Prefer, any, away, corner (+8 more)

### Community 157 - "FloorPlan"
Cohesion: 0.13
Nodes (15): CityPlan.Rect, .area, FloorPlan, .height, SharedEdge, .length, .middle, StairPlan (+7 more)

### Community 158 - "RendererController"
Cohesion: 0.11
Nodes (15): .buildingPlan, .buildingStats, .cameraPosition, .walker, Float, .plantStats, RendererController, .debugActive (+7 more)

### Community 159 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.16
Nodes (19): intersection_params, intersection_type, assumeCurveShape(), clusterWalk(), committedCurve(), CurveLevels, isCurveHit(), Levels (+11 more)

### Community 162 - "AppKit"
Cohesion: 0.15
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.11
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "LumenCards"
Cohesion: 0.14
Nodes (13): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+5 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): isFar(), constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "Measuring MetalRenderer"
Cohesion: 0.12
Nodes (11): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table, Proving a refactor changed nothing, Scorers and other tools (+3 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 172 - "VSM.metal"
Cohesion: 0.17
Nodes (40): constant, device, float3, float4, fragment, kernel, Light, read (+32 more)

### Community 173 - "Float"
Cohesion: 0.16
Nodes (11): Choice, Finish, MaterialDef, Palette, StyleDraw, Decoder, Encoder, Float (+3 more)

### Community 174 - "GPUProfiler"
Cohesion: 0.08
Nodes (19): MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+11 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.14
Nodes (18): Color, GraphicsContext, FloorPlanView, .body, .help, .status, .storeys, .toolbar (+10 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "PlantParam"
Cohesion: 0.11
Nodes (15): L, ParamRow, .body, .body, Root, .body, PlantParam, .isInteger (+7 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 181 - "TextureStreamWork"
Cohesion: 0.23
Nodes (5): MTLCommandBuffer, .residentLevels, TextureStreamWork, URL, TextureStreamerTests

### Community 182 - "Map"
Cohesion: 0.18
Nodes (9): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, MTLCommandQueue, MTLDevice (+1 more)

### Community 183 - "LoadingOverlay"
Cohesion: 0.14
Nodes (9): NSFont, NSPoint, NSView, LoadingOverlay, .isEnabled, Row, NSCoder, NSTextField (+1 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.07
Nodes (34): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsShape, GPURasterMesh, .worldToView, PhysicsCandidate (+26 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "Clip"
Cohesion: 0.25
Nodes (7): Clip, graft, habitat, leaves, level, look, Clipboard

### Community 190 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.28
Nodes (8): ColliderGrid, Input, Moving, Float, SIMD2, Walker, .eyePosition, .height

### Community 193 - "BuildingEditorTests"
Cohesion: 0.17
Nodes (6): BuildingEditorTests, Host, Float, UInt64, URL, Void

### Community 194 - "SkyImage"
Cohesion: 0.21
Nodes (6): Atmosphere, SkyImage, Float, Set, UnsafeMutableBufferPointer, URL

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - ".begin"
Cohesion: 0.30
Nodes (4): Snapshot, .isIdle, Stream, LoadActivityTests

### Community 197 - "Backend"
Cohesion: 0.15
Nodes (10): NSRect, FlippedView, .isFlipped, FrameGraphView, NSView, Backend, auto, cpu (+2 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "uint"
Cohesion: 0.25
Nodes (14): candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart() (+6 more)

### Community 200 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.40
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "String"
Cohesion: 0.06
Nodes (28): Error, MTLBlitCommandEncoder, MTLRenderPassDescriptor, LoadError, unreadable, CatalogRegistry, T, GLTFError (+20 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - ".stages"
Cohesion: 0.20
Nodes (12): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLTexture (+4 more)

### Community 206 - "Buffer"
Cohesion: 0.25
Nodes (7): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, metal3, metal4, MTLHeap, UInt64

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

### Community 213 - "BuildingEditorPanel"
Cohesion: 0.22
Nodes (7): BuildingEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 220 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 221 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 222 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - ".updatePrimitives"
Cohesion: 0.20
Nodes (5): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer

### Community 225 - ".encoder"
Cohesion: 0.23
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 226 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (8): NSWindowDelegate, PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 227 - "RenderThread"
Cohesion: 0.20
Nodes (4): Notification, RenderThread, Thread, Void

### Community 228 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 229 - "Key"
Cohesion: 0.23
Nodes (6): Hashable, Key, PipelineCache, .count, MTLComputePipelineState, Value

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".workshop"
Cohesion: 0.24
Nodes (6): Building editor: handoff (2026-10-08), M1 Max numbers, Not checked anywhere, To do on the M4 Max, BuildingWorkshopTests, Void

### Community 233 - "ProceduralTextures"
Cohesion: 0.36
Nodes (6): ProceduralTextures, Float, Sample, SIMD2, UInt32, URL

### Community 234 - "RenderPass4"
Cohesion: 0.17
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Double"
Cohesion: 0.13
Nodes (16): Double, World, .anchorTile, .start, City, Flora, Ground, Highway (+8 more)

### Community 237 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 239 - "TLASUpdate"
Cohesion: 0.22
Nodes (7): MTL4InstanceAccelerationStructureDescriptor, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLInstanceAccelerationStructureDescriptor, TLASUpdate, .descriptor, .descriptor4

### Community 240 - "Clip"
Cohesion: 0.22
Nodes (8): Clip, facade, furnish, look, massing, plan, rooms, Clipboard

### Community 241 - "CameraTrack"
Cohesion: 0.07
Nodes (21): CameraTrack, .duration, Key, Float, Particles, bubbles, dust, embers (+13 more)

### Community 242 - "PressButton"
Cohesion: 0.22
Nodes (4): PressButton, .body, Void, SwiftUI

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 246 - "Model"
Cohesion: 0.22
Nodes (8): Model, heading, item, State, done, failed, running, streaming

### Community 247 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

### Community 248 - "DebugInfo"
Cohesion: 0.25
Nodes (7): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles

### Community 249 - "RasterScene"
Cohesion: 0.28
Nodes (5): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLTexture

### Community 250 - "Tab"
Cohesion: 0.25
Nodes (8): Tab, facade, floors, furnish, look, massing, rooms, site

### Community 251 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 254 - "Heavens"
Cohesion: 0.25
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - "Heightfield"
Cohesion: 0.29
Nodes (6): Baked, bricks, heights, Heightfield, .hi, SIMD2

### Community 256 - "Tab"
Cohesion: 0.29
Nodes (7): Tab, ages, boughs, habitat, leaves, look, stems

### Community 257 - ".generate"
Cohesion: 0.38
Nodes (3): Maps, UInt8, ProceduralTextureTests

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 259 - "Section"
Cohesion: 0.33
Nodes (4): NSColor, NSStackView, Section, NSCoder

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, furniture, glass, solid, stair, UInt8

### Community 261 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 262 - "Liquids"
Cohesion: 0.33
Nodes (6): Liquids, all, blood, honey, .title, water

## Knowledge Gaps
- **1735 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1730 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2334 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **19 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Codable`, `.simplify`, `PlantEditorModel`, `RenderView`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `.update`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `SceneSettings`, `RadianceCascades`, `GeneratedCache`, `Mesh`, `SettingsTable.swift`, `XCTestCase`, `SceneBuffers`, `View`, `LumenScene`, `Crowd`, `.part`, `DebugPanel`, `SceneKind`, `.xyz`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `Int32`, `RenderPass`, `VoxelGrids`, `TextureStreamer`, `AABB`, `KernelVariants`, `LoadActivity`, `.meshes`, `BuildingEditorModel`, `.city`, `Float`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `Metal3Pass`, `PhysicsWorld`, `MuscleTests`, `BuildingSpec`, `SoftModel`, `Bool`, `CaseIterable`, `SettingsTable`, `Config`, `BuildingStyleDef`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `GLTFModel`, `.library`, `Flora`, `PlantTracing`, `.buildWorld`, `SDFShape`, `RenderSettings`, `Building`, `TraversalStats`, `Benchmark`, `RoomType`, `Images`, `VoxelLOD`, `.write`, `.createShadingResources`, `.writeDescriptors`, `Foliage`, `QuartzCore`, `MeshBuilder`, `Pipelines`, `Habitat`, `Curve`, `MeshSDFBuilderTests`, `Furnisher`, `FloorPlan`, `RendererController`, `FBXFile`, `Lift`, `LumenCards`, `FBXError`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `TextureStreamWork`, `LoadingOverlay`, `FoliageRuntimeTests`, `SIMD3`, `Role`, `ColliderGrid`, `BuildingEditorTests`, `SkyImage`, `.begin`, `Backend`, `WindFrame`, `RagdollTests`, `FurnitureItem`, `String`, `.stages`, `Terrain`, `.updatePrimitives`, `.encoder`, `Key`, `.commit`, `ProceduralTextures`, `RenderPass4`, `Double`, `WorldPlace`, `TLASUpdate`, `CameraTrack`, `DebugInfo`, `RasterScene`, `Heightfield`, `.generate`, `Liquids`, `.setTexture`, `.setBytes`, `.init`?**
  _High betweenness centrality (0.314) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `restirGIInitialKernel`, `traceKernel`, `PlantParam`, `.createShadingResources`, `Pipelines`, `flagOn`, `Kernel`?**
  _High betweenness centrality (0.109) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `VoxelLOD`, `.write`, `FluidSurface.metal`, `MeshBuilder`, `Pipelines`, `Int`, `SkinnedCharacter`, `Renderer`, `TraceScene`, `Lift`, `GeneratedCache`, `SceneBuffers`, `LoadingOverlay`, `MuscleAtlas`, `VirtualTracing`, `CityPlan`, `String`, `VoxelGrids`, `TextureStreamer`, `Terrain`, `LoadActivity`, `.meshes`, `Capabilities`, `Upscaler`, `Key`, `ProceduralTextures`, `BuildingStyleDef`, `GLTFModel`, `PlantTracing`?**
  _High betweenness centrality (0.104) - this node is a cross-community bridge._
- **Are the 49 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 49 INFERRED edges - model-reasoned connections that need verification._
- **Are the 33 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 33 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1735 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.03963585434173669 - nodes in this community are weakly interconnected._