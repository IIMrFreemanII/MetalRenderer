# Graph Report - procedural-character-creation-cb1a51  (2026-10-09)

## Corpus Check
- 285 files · ~1,344,488 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 8127 nodes · 25303 edges · 270 communities (247 shown, 23 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3670 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b417a0a5`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- BuildingStyleDef
- Lights.metal
- traceKernel
- PlantCatalog
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- CGFloat
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- CharacterEditorModel
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- float4x4
- XCTestCase
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- .shared
- regirBuildKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- CodingKeys
- CaseIterable
- VSMTargets
- SceneBuffers
- .init
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- Int
- Metal3Pass
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
- MeshData
- Direct Rendering Stress Test 32
- FaceRig
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
- CharacterBase
- VoxelGrids
- TextureStreamer
- FoliageTextures
- KernelVariants
- ab.sh
- Map
- instanceRecord
- uint
- VirtualBLAS
- BuildingEditorModel
- .city
- Capabilities
- Mesh
- Images
- SurfaceKind
- Where things are
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- MuscleTests
- Building
- physCollide
- ClusterBox
- SoftModel
- uint4
- Bool
- String
- EnvVariable
- World
- BuildingCatalog
- FaceSculpt
- .library
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysPoints
- render.sh
- BuildingAssembler
- Interior
- RendererController
- .build
- Foliage
- same.sh
- Key
- baseline.sh
- .load
- .buildWorld
- SDFShape
- Raster.metal
- RenderSettings
- Float
- lumenCardRadiosityKernel
- Config
- PlantWind
- PlantEditorTests
- Kind
- Benchmark
- RoomType
- BVHBuilder
- VoxelLOD
- .d
- FluidSurface.metal
- RasterClusters.metal
- flagOn
- .env
- RenderView
- PlantTracing
- VSMCounters
- .load
- Hit
- liquidKernel
- MeshBuilder
- Pipelines
- Species
- Curve
- Where things are
- Furnisher
- FloorPlan
- DebugPanel
- FBXFile
- TraceScene
- Intersect.metal
- AppKit
- Lift
- related.sh
- CameraTrack
- RTVoxels
- .buildGallery
- VGParams
- CPU (Swift) practices for MetalRenderer
- .add
- .load
- VSM.metal
- Post.metal
- GPUProfiler
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- FleshFigure
- .writeDescriptors
- PlantTracingTests
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- Role
- Camera
- float3
- VSMInstance
- GLTFModel
- PhysicsBody
- SettingsStore
- RasterCounters
- .addHair
- LightKind
- SDFBox
- Float
- BlueNoise
- RagdollTests
- FurnitureItem
- Optional
- .encoder
- .commit
- PostParams
- .trees
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- StressSceneTests
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- .generate
- Hair.metal
- CrowdSkinParams
- CharacterEditorPanel
- SceneShading
- SkyParams
- float4
- SkinShell
- KernelVariantsTests
- RenderThread
- Buffer
- PipelineCache
- HairBSDF
- .commit
- SceneBuffersTests
- .vgdebug
- RenderPass4
- BVHTests
- Double
- .origin
- LumenParams
- .key
- PhysicsSkinAttach
- Stage
- PlantEditorPanel
- Core
- .mark
- Region
- LoadingOverlay
- Op
- WindFrame
- Host
- Stored
- WallGrid
- PhysicsMuscle
- Types.metal
- Heavens
- Where new code belongs
- makeRay
- vsmFragment
- .useResource
- Phyllotaxis
- Int32
- Kind
- .capture
- .setBytes
- .dispatchThreads
- .setComputePipelineState
- LightMotion
- Shape
- .torusKnotMesh
- .init

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 546 edges
2. `Scene` - 337 edges
3. `PhysicsWorld` - 275 edges
4. `Renderer` - 270 edges
5. `simd` - 154 edges
6. `Kernel` - 154 edges
7. `SIMD4` - 153 edges
8. `Foliage` - 151 edges
9. `Benchmark` - 117 edges
10. `RenderSettings` - 115 edges

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

## Communities (270 total, 23 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (49): AABB, .area, .centroid, .isEmpty, .bounds, GPUEmissiveTriangle, .viewNote, .walkerStatus (+41 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.18
Nodes (25): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+17 more)

### Community 3 - "BuildingStyleDef"
Cohesion: 0.06
Nodes (42): IntChoiceRow, .body, Balustrade, bars, glass, solid, PlanShape, courtyard (+34 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (78): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+70 more)

### Community 5 - "traceKernel"
Cohesion: 0.09
Nodes (46): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), laineKarrasPermutation(), luminance(), makeSampler() (+38 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.06
Nodes (23): .key, .savedDef, Foliage.Phyllotaxis, FoliageTextures.Kind, PlantCatalog, .all, .count, .covers (+15 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.07
Nodes (26): ObservableObject, Clip, graft, habitat, leaves, level, look, Clipboard (+18 more)

### Community 11 - "CGFloat"
Cohesion: 0.12
Nodes (18): NSFont, NSTextField, FrameOutput, Headless, LayerSurface, .backingScale, .isVisible, .outputSize (+10 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), RC_MAX_CASCADES, constant, device, float3, float4, kernel (+21 more)

### Community 13 - "FramePlan"
Cohesion: 0.14
Nodes (17): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+9 more)

### Community 14 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.13
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (14): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+6 more)

### Community 17 - "CharacterEditorModel"
Cohesion: 0.04
Nodes (49): Group, CharacterDNA, .key, T, UInt64, CharacterEditorHost, CharacterEditorModel, .dna (+41 more)

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
Nodes (74): constant, device, float2, float3, float4, kernel, Light, read_write (+66 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "float4x4"
Cohesion: 0.15
Nodes (13): Parts, float4x4, Hall, Loop, .length, Props, Float, SIMD2 (+5 more)

### Community 24 - "XCTestCase"
Cohesion: 0.19
Nodes (12): Result, Data, VirtualMesh, GPUCut, Error, MTLComputePipelineState, MTLDevice, Set (+4 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.10
Nodes (20): CharacterBuilder, CharacterShape, MacroRig, Float, simd_float3x3, GPUJoint, .parent, Clip (+12 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.08
Nodes (25): NSControl, NSGridView, NSObject, Sides, backToBack, corner, .edges, free (+17 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (81): To do on the M4 Max, 8. Pipelines and resources, MetalKit, SkyImage, Set, GPUFogParams, .reflectionPassFlags, GPUPostParams (+73 more)

### Community 31 - ".shared"
Cohesion: 0.15
Nodes (6): GPUMesh, UInt64, MTLDevice, RasterSceneTests, Float, MeshGeometry

### Community 32 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.10
Nodes (47): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+39 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.08
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.11
Nodes (15): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, Data, T (+7 more)

### Community 39 - "Physics.metal"
Cohesion: 0.13
Nodes (56): constant, device, int3, kernel, uint, physActivate(), physCell(), physColourPairs() (+48 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "CodingKeys"
Cohesion: 0.06
Nodes (28): CodingKey, Keys, hi, lo, CharacterDNA.Look, CharacterDNA.Macro, CodingKeys, age (+20 more)

### Community 42 - "CaseIterable"
Cohesion: 0.03
Nodes (101): CaseIterable, Tab, facade, floors, furnish, look, massing, rooms (+93 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (33): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+25 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (34): Error, LoadError, unreadable, .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives (+26 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.05
Nodes (40): Int8, Baked, bricks, heights, GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking (+32 more)

### Community 48 - "AppDelegate"
Cohesion: 0.09
Nodes (18): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindowDelegate, BuildingEditorPanel, .isVisible, .wasVisible, Notification (+10 more)

### Community 49 - "Crowd"
Cohesion: 0.12
Nodes (20): .parts, Crowd, .liveStates, Face, Motion, .isBlend, Part, Slot (+12 more)

### Community 50 - "Int"
Cohesion: 0.03
Nodes (77): MTLAccelerationStructure, Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState (+69 more)

### Community 51 - "Metal3Pass"
Cohesion: 0.06
Nodes (19): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+11 more)

### Community 52 - "SceneKind"
Cohesion: 0.04
Nodes (44): SceneKind, area, buildings, .cameraFromScene, characters, city, cityNight, cornell (+36 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.06
Nodes (32): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+24 more)

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
Cohesion: 0.09
Nodes (28): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+20 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (108): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+100 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "FaceRig"
Cohesion: 0.11
Nodes (20): CharacterKit, UInt32, Entry, FacePlayer, FaceRig, FaceState, Group, leftEye (+12 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.06
Nodes (24): Float, UnsafeBufferPointer, .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged, MTLResource, Content (+16 more)

### Community 73 - "CityPlan"
Cohesion: 0.10
Nodes (23): Block, CityPlan, Edge, open, party, street, Lamp, Lot (+15 more)

### Community 74 - "FluidSystem"
Cohesion: 0.10
Nodes (20): .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem, .capacity (+12 more)

### Community 75 - "simd"
Cohesion: 0.05
Nodes (4): CoreGraphics, Foundation, ImageIO, simd

### Community 76 - "CharacterBase"
Cohesion: 0.12
Nodes (18): Character creator: handoff, Decisions (the user's), Deviations from the plan, and why, Open, Phases, Traps found, CharacterBase, Hand (+10 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.17
Nodes (16): FoliageVoxels, Grid, Piece, Plant, Float, UInt32, BoxData, MTLAccelerationStructure (+8 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.07
Nodes (30): MTLRegion, MTLSparseTextureMappingMode, LoadStep, Entry, Level, SparseMapping, Data, MTLBuffer (+22 more)

### Community 79 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.19
Nodes (17): Pipelines: `Pipelines.swift`, Hashable, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count (+9 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Map"
Cohesion: 0.10
Nodes (19): Map, Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled (+11 more)

### Community 83 - "instanceRecord"
Cohesion: 0.08
Nodes (52): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+44 more)

### Community 84 - "uint"
Cohesion: 0.24
Nodes (17): candidate(), candidateIndex(), candidatePart(), card(), committed(), committedPart(), countedHit(), instance() (+9 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.15
Nodes (19): Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice (+11 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.04
Nodes (85): BuildingEditorHost, BuildingEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key, .savedDef (+77 more)

### Community 87 - ".city"
Cohesion: 0.22
Nodes (4): Block, Data, T, WorldTests

### Community 88 - "Capabilities"
Cohesion: 0.21
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Mesh"
Cohesion: 0.13
Nodes (19): Card, Plant, Skeleton, LeafAnchor, LeafShape, blade, kite, needle (+11 more)

### Community 90 - "Images"
Cohesion: 0.20
Nodes (3): 6. Math, Modes, Images

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (24): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+16 more)

### Community 92 - "Where things are"
Cohesion: 0.20
Nodes (6): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests, Void

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.09
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.06
Nodes (52): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+44 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.12
Nodes (9): GPUPhysicsGrab, Cloth, Set, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape (+1 more)

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (12): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, SDFShape, UInt32, MuscleTests (+4 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (49): Building, BuildingGenerator, BuildingSpec, .style, Detail, flat, full, Footprint (+41 more)

### Community 100 - "physCollide"
Cohesion: 0.12
Nodes (30): thread, physAdd(), physAddFound(), physAgree(), physArea(), PhysCandidate, n, pa (+22 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (23): ArraySlice, centre, GPUPhysicsParticle, GPUSoftVertex, .particleCellSize, Flesh, SIMD2, NearCache (+15 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (45): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+37 more)

### Community 104 - "Bool"
Cohesion: 0.12
Nodes (19): PlanDoor, PlanRoom, .area, StoreyPlanner, Float, SIMD2, SplitMix64, Rect (+11 more)

### Community 105 - "String"
Cohesion: 0.04
Nodes (42): Settings: `SettingsTable.swift`, Tool, door, look, merge, split, type, wall (+34 more)

### Community 106 - "EnvVariable"
Cohesion: 0.04
Nodes (58): Bound, F, format, on, .reservoirCount, Control, checkbox, custom (+50 more)

### Community 107 - "World"
Cohesion: 0.17
Nodes (12): World, .anchorTile, .start, Ground, Placement, Road, SplitMix64, UInt32 (+4 more)

### Community 108 - "BuildingCatalog"
Cohesion: 0.08
Nodes (26): Encodable, JSONEncoder, interior, .currentOverride, .currentRef, BuildingCatalog, .fingerprint, .launch (+18 more)

### Community 109 - "FaceSculpt"
Cohesion: 0.12
Nodes (16): FaceParts, Material, brows, iris, lips, mouth, pupil, sclera (+8 more)

### Community 110 - ".library"
Cohesion: 0.09
Nodes (19): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+11 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (18): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.11
Nodes (20): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+12 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.07
Nodes (5): Metal, MetalFX, MetalRenderer, QuartzCore, XCTest

### Community 115 - "PhysPoints"
Cohesion: 0.12
Nodes (17): physContactPush(), PhysicsContact, anchorA, anchorB, lambda, normal, PhysPoints, pa (+9 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.14
Nodes (15): BuildingAssembler, BuildingTier, .top, Cell, .center, .width, Opening, Float (+7 more)

### Community 118 - "Interior"
Cohesion: 0.10
Nodes (29): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+21 more)

### Community 119 - "RendererController"
Cohesion: 0.07
Nodes (26): .buildingPlan, .buildingStats, .cameraPosition, .walker, Float, .characterStats, DebugInfo, Float (+18 more)

### Community 120 - ".build"
Cohesion: 0.14
Nodes (15): Cluster, Group, .isRoot, Float, SIMD2, UInt32, UInt64, UInt8 (+7 more)

### Community 121 - "Foliage"
Cohesion: 0.14
Nodes (15): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.20
Nodes (8): Foliage.Curve, Key, crown, linear, points, taper, Decoder, Encoder

### Community 125 - ".load"
Cohesion: 0.19
Nodes (11): CustomStringConvertible, GLTFError, .description, invalid, unsupported, Image, Material, Data (+3 more)

### Community 126 - ".buildWorld"
Cohesion: 0.20
Nodes (7): WalkArea, BuildingKit, Float, UInt32, TextureSource, .identity, .rawPixels

### Community 127 - "SDFShape"
Cohesion: 0.06
Nodes (40): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+32 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (42): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+34 more)

### Community 129 - "RenderSettings"
Cohesion: 0.04
Nodes (90): To do on the M4 Max, Codable, Equatable, Look, Macro, Float, Cover, UInt32 (+82 more)

### Community 130 - "Float"
Cohesion: 0.17
Nodes (14): Level, Float, Card, Carve, Graft, Grower, LeafRecipe, Level (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.09
Nodes (47): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+39 more)

### Community 132 - "Config"
Cohesion: 0.16
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

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
Cohesion: 0.06
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (39): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+31 more)

### Community 138 - "BVHBuilder"
Cohesion: 0.18
Nodes (11): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+3 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): .megabytes, Entry, Float, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - ".d"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.08
Nodes (45): RasterClusterMeshOut, constant, device, float4, kernel, read, texture2d, thread (+37 more)

### Community 143 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 144 - ".env"
Cohesion: 0.12
Nodes (11): Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't, A/B protocol, Kernel variants, Launch time (+3 more)

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder (+10 more)

### Community 146 - "PlantTracing"
Cohesion: 0.13
Nodes (18): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+10 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "liquidKernel"
Cohesion: 0.15
Nodes (19): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device (+11 more)

### Community 151 - "MeshBuilder"
Cohesion: 0.15
Nodes (12): OptionSet, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+4 more)

### Community 152 - "Pipelines"
Cohesion: 0.07
Nodes (36): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, ComputePass, FrameEncoder, PrimitiveRefit, PrimitiveWork, .encoderCount, RenderAttachments, MTLPrimitiveAccelerationStructureDescriptor (+28 more)

### Community 153 - "Species"
Cohesion: 0.17
Nodes (11): RawRepresentable, Species, .description, .hasBoughs, .isTree, Habitat, Ramp, Float (+3 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Where things are"
Cohesion: 0.13
Nodes (12): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, Where things are, P, BuildingMutate, BuildingParams (+4 more)

### Community 156 - "Furnisher"
Cohesion: 0.17
Nodes (14): Side, Furnisher, Light, Prefer, any, away, corner, middle (+6 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (6): CGSize, FloorPlan, .height, BuildingPlanTests, Float, SIMD2

### Community 158 - "DebugPanel"
Cohesion: 0.08
Nodes (18): NSColor, NSRect, NSStackView, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView (+10 more)

### Community 159 - "FBXFile"
Cohesion: 0.07
Nodes (41): Compression, IteratorProtocol, Sequence, simd_double4x4, simd_quatd, Children, Connection, Contents (+33 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.20
Nodes (20): geometry_type, intersection_params, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit(), commitCurve() (+12 more)

### Community 162 - "AppKit"
Cohesion: 0.16
Nodes (5): AppKit, Combine, Element, Array, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "CameraTrack"
Cohesion: 0.10
Nodes (13): CameraTrack, .duration, Key, Float, Particles, bubbles, dust, embers (+5 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (33): constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster, childGroup (+25 more)

### Community 169 - "CPU (Swift) practices for MetalRenderer"
Cohesion: 0.10
Nodes (15): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)) (+7 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - ".load"
Cohesion: 0.11
Nodes (12): CacheFile, Data, URL, Data, URL, BlobWriter, CharacterLibrary, .directory (+4 more)

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (22): float3, Light, read, SCENE_ACCEL, texture2d, thread, uint2, write (+14 more)

### Community 173 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 174 - "GPUProfiler"
Cohesion: 0.06
Nodes (29): MTL4InstanceAccelerationStructureDescriptor, MTLBlitCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLRenderPassDescriptor (+21 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.16
Nodes (18): Color, GraphicsContext, FloorPlanView, .body, .help, .picked, .status, .storeys (+10 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "PlantParam"
Cohesion: 0.16
Nodes (13): L, ParamRow, .body, .body, Root, .body, PlantParam, .isInteger (+5 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "uint"
Cohesion: 0.32
Nodes (16): constant, device, float4, kernel, uint, vertex, vsmAllocKernel(), vsmChunksKernel() (+8 more)

### Community 181 - "FleshFigure"
Cohesion: 0.11
Nodes (22): MuscleSpec, Side, back, front, out, Bone, FleshFigure, Role (+14 more)

### Community 182 - ".writeDescriptors"
Cohesion: 0.27
Nodes (5): Tests, float3x3, Float, UInt32, Wind

### Community 183 - "PlantTracingTests"
Cohesion: 0.31
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.08
Nodes (26): Atmosphere, Float, GPUPhysicsShape, GPURasterMesh, .worldToView, PhysicsCandidate, .middle, PhysicsManifold (+18 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "Camera"
Cohesion: 0.12
Nodes (11): Darwin, Camera, .forward, .right, .up, rotate(), Float, PlantStats (+3 more)

### Community 190 - "float3"
Cohesion: 0.11
Nodes (30): float3, physAcross(), physAnchorTurnWeight(), physBox(), physBoxGradient(), physContactKick(), physDampJoint(), physHold() (+22 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "GLTFModel"
Cohesion: 0.20
Nodes (9): GLTFModel, .triangleCount, Light, Entry, File, PropLibrary, Float, URL (+1 more)

### Community 193 - "PhysicsBody"
Cohesion: 0.13
Nodes (17): physBetween(), physConj(), PhysicsBody, angular, info, invInertia, position, prevPosition (+9 more)

### Community 194 - "SettingsStore"
Cohesion: 0.14
Nodes (9): The pass, The pass after a feature, The report and the commit message, What stays fixed, What to look for, base, SettingsStore, Any (+1 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

### Community 197 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "Float"
Cohesion: 0.20
Nodes (13): EmissiveStrength, Kind, directional, point, spot, MaterialDef, MaterialExtensions, Mesh (+5 more)

### Community 200 - "BlueNoise"
Cohesion: 0.27
Nodes (6): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.40
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "Optional"
Cohesion: 0.33
Nodes (3): MTLCommandEncoder, Optional, .clipName

### Community 204 - ".encoder"
Cohesion: 0.19
Nodes (6): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope

### Community 205 - ".commit"
Cohesion: 0.21
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 206 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 207 - ".trees"
Cohesion: 0.19
Nodes (7): Float, SIMD2, UInt32, UInt64, Terrain, .cell, Flora

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "float4"
Cohesion: 0.05
Nodes (38): float4, physBreeze(), PhysicsFleshFibre, compliance, g, muscle, pad0, pad1 (+30 more)

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

### Community 220 - "CrowdSkinParams"
Cohesion: 0.15
Nodes (13): CrowdSkinParams, bindBase, currentBase, faceBase, faceScale, faceTargets, firstSlot, groupBase (+5 more)

### Community 221 - "CharacterEditorPanel"
Cohesion: 0.21
Nodes (7): CharacterEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 222 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 225 - "SkinShell"
Cohesion: 0.32
Nodes (6): SkinOptions, SkinShell, Float, MeshGeometry, SIMD2, UInt32

### Community 226 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 227 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 228 - "Buffer"
Cohesion: 0.14
Nodes (11): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLCommandBuffer, MTLHeap (+3 more)

### Community 229 - "PipelineCache"
Cohesion: 0.47
Nodes (3): PipelineCache, .count, Value

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "SceneBuffersTests"
Cohesion: 0.22
Nodes (6): SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 233 - ".vgdebug"
Cohesion: 0.22
Nodes (6): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are

### Community 234 - "RenderPass4"
Cohesion: 0.16
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState

### Community 235 - "BVHTests"
Cohesion: 0.27
Nodes (5): BVHTests, Float, StaticString, UInt, UInt64

### Community 236 - "Double"
Cohesion: 0.22
Nodes (6): Double, City, Highway, Roadbeds, Float, SIMD2

### Community 237 - ".origin"
Cohesion: 0.26
Nodes (5): Float, Float, SIMD2, WorldPlace, .anchor

### Community 238 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 240 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (7): PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 245 - "Region"
Cohesion: 0.15
Nodes (13): Region, arm, foot, hand, head, leftEye, leg, lowerTeeth (+5 more)

### Community 246 - "LoadingOverlay"
Cohesion: 0.11
Nodes (14): NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item, Row (+6 more)

### Community 247 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

### Community 248 - "WindFrame"
Cohesion: 0.43
Nodes (6): PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 249 - "Host"
Cohesion: 0.43
Nodes (3): Host, Float, Void

### Community 250 - "Stored"
Cohesion: 0.40
Nodes (5): Stored, .array, .count, made, mapped

### Community 251 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 254 - "Heavens"
Cohesion: 0.21
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - "Where new code belongs"
Cohesion: 0.40
Nodes (5): 4. CPU↔GPU data layout, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Things that are not structures yet, Where new code belongs, validateGPULayouts()

### Community 256 - "makeRay"
Cohesion: 0.22
Nodes (14): boxCandidate(), clusterWalk(), makeRay(), float3, octDecode(), Ray, direction, origin (+6 more)

### Community 259 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 260 - "Int32"
Cohesion: 0.09
Nodes (30): Kind, furniture, glass, solid, stair, Float, Bump, CharacterMorphs (+22 more)

### Community 261 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 262 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 266 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 267 - "Shape"
Cohesion: 0.67
Nodes (3): Shape, box, sphere

## Knowledge Gaps
- **1831 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1826 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2452 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **23 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `BuildingStyleDef`, `PlantCatalog`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `CharacterEditorModel`, `LightTable`, `float4x4`, `XCTestCase`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `.shared`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `.init`, `LumenScene`, `Crowd`, `Metal3Pass`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `FaceRig`, `VirtualTracing`, `CityPlan`, `FluidSystem`, `CharacterBase`, `VoxelGrids`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `Map`, `VirtualBLAS`, `BuildingEditorModel`, `.city`, `Mesh`, `Images`, `SurfaceKind`, `Upscaler`, `FluidTests`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Bool`, `String`, `EnvVariable`, `World`, `BuildingCatalog`, `FaceSculpt`, `.library`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `RendererController`, `.build`, `Foliage`, `.load`, `.buildWorld`, `SDFShape`, `RenderSettings`, `Float`, `Config`, `PlantEditorTests`, `Benchmark`, `RoomType`, `BVHBuilder`, `VoxelLOD`, `.d`, `PlantTracing`, `MeshBuilder`, `Pipelines`, `Species`, `Curve`, `Where things are`, `Furnisher`, `FloorPlan`, `DebugPanel`, `FBXFile`, `AppKit`, `Lift`, `.buildGallery`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `.writeDescriptors`, `PlantTracingTests`, `FoliageRuntimeTests`, `SIMD3`, `Role`, `Camera`, `GLTFModel`, `.addHair`, `LightKind`, `Float`, `BlueNoise`, `RagdollTests`, `FurnitureItem`, `.commit`, `.trees`, `StressSceneTests`, `SkinShell`, `Buffer`, `PipelineCache`, `.commit`, `SceneBuffersTests`, `RenderPass4`, `BVHTests`, `Double`, `.origin`, `.key`, `LoadingOverlay`, `WindFrame`, `Stored`, `Phyllotaxis`, `Int32`, `.setBytes`, `.torusKnotMesh`?**
  _High betweenness centrality (0.254) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `BuildingStyleDef`, `PlantCatalog`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `translate`, `CharacterEditorModel`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `GeneratedCache`, `CodingKeys`, `CaseIterable`, `SceneBuffers`, `Int`, `SceneKind`, `MuscleAtlas`, `FaceRig`, `VirtualTracing`, `VoxelGrids`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `Map`, `VirtualBLAS`, `BuildingEditorModel`, `.city`, `Capabilities`, `Mesh`, `Images`, `Where things are`, `Upscaler`, `FluidTests`, `Bool`, `EnvVariable`, `World`, `BuildingCatalog`, `.library`, `CurveEditor`, `WorldTile`, `RendererController`, `.build`, `Foliage`, `Key`, `.load`, `.buildWorld`, `RenderSettings`, `Config`, `PlantEditorTests`, `Kind`, `Benchmark`, `RoomType`, `.env`, `.load`, `Pipelines`, `Species`, `Curve`, `Where things are`, `FloorPlan`, `DebugPanel`, `FBXFile`, `Lift`, `CameraTrack`, `.add`, `.load`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `SIMD3`, `GLTFModel`, `SettingsStore`, `Float`, `.encoder`, `.commit`, `KernelVariantsTests`, `Buffer`, `.commit`, `SceneBuffersTests`, `BVHTests`, `.origin`, `.mark`, `LoadingOverlay`, `Op`, `Int32`, `Kind`?**
  _High betweenness centrality (0.170) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `BuildingStyleDef`, `PlantCatalog`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `CharacterEditorModel`, `float4x4`, `XCTestCase`, `SkinnedCharacter`, `SettingsPanel`, `Renderer`, `.shared`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `AppDelegate`, `Crowd`, `Int`, `SceneKind`, `PhysicsWorld`, `FaceRig`, `VirtualTracing`, `CityPlan`, `FluidSystem`, `CharacterBase`, `VoxelGrids`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `Map`, `VirtualBLAS`, `BuildingEditorModel`, `.city`, `Mesh`, `SurfaceKind`, `Where things are`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `String`, `EnvVariable`, `BuildingCatalog`, `FaceSculpt`, `.library`, `WorldTile`, `BuildingAssembler`, `Interior`, `RendererController`, `.build`, `Foliage`, `.buildWorld`, `SDFShape`, `RenderSettings`, `Float`, `Config`, `Benchmark`, `RoomType`, `BVHBuilder`, `VoxelLOD`, `.env`, `RenderView`, `PlantTracing`, `.load`, `MeshBuilder`, `Pipelines`, `Species`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `FBXFile`, `Lift`, `.load`, `GPUProfiler`, `PlantParam`, `FleshFigure`, `.writeDescriptors`, `FoliageRuntimeTests`, `SIMD3`, `Camera`, `.addHair`, `LightKind`, `RagdollTests`, `.encoder`, `CharacterEditorPanel`, `RenderThread`, `.commit`, `SceneBuffersTests`, `Double`, `.origin`, `.key`, `PlantEditorPanel`, `Core`, `LoadingOverlay`, `WindFrame`, `WallGrid`, `Heavens`, `Int32`, `.capture`?**
  _High betweenness centrality (0.106) - this node is a cross-community bridge._
- **Are the 54 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 54 INFERRED edges - model-reasoned connections that need verification._
- **Are the 35 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 35 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1831 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.042010719976821674 - nodes in this community are weakly interconnected._