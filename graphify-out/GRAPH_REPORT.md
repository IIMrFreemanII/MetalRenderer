# Graph Report - procedural-character-creation-cb1a51  (2026-10-09)

## Corpus Check
- 291 files · ~1,367,708 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 8343 nodes · 26221 edges · 270 communities (245 shown, 25 thin omitted)
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 3792 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0ae1f679`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- pcgHash
- CharacterEditorModel
- Float
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- LayerSurface
- rcTraceMergeKernel
- FramePlan
- SDFBuffers
- Metal4Frame
- translate
- .d
- roundToHalf
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
- CharacterKit
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- FaceSculpt
- String
- VSMTargets
- SceneBuffers
- BuildingEditorModel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- VirtualGeometry
- Float
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
- InstanceData
- Direct Rendering Stress Test 32
- Config
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
- Int
- FoliageTextures
- KernelVariants
- ab.sh
- LoadActivity
- instanceRecord
- Ray
- VirtualBLAS
- LotRef
- .bytes
- Capabilities
- Foliage
- CharacterDNA
- ProceduralTextures
- flagOn
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- Species
- Building
- float3
- ClusterBox
- SoftModel
- uint4
- Rect
- CaseIterable
- Bool
- SkinTextures
- View
- EnvVariable
- RasterScene
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysPush
- render.sh
- BuildingAssembler
- Interior
- .buildGallery
- MeshSDF
- AABB
- same.sh
- Key
- baseline.sh
- BuildingPlan
- .buildWorld
- BVHBuilder
- Raster.metal
- .load
- CharacterBase
- lumenCardRadiosityKernel
- PlantCatalog
- PlantWind
- Where things are
- Kind
- Benchmark
- RoomType
- .pieces
- Map
- BlueNoise
- FluidSurface.metal
- RasterClusters.metal
- regirBuildKernel
- .buildings
- RenderView
- .writeDescriptors
- VSMCounters
- .load
- Hit
- QuartzCore
- MeshBuilder
- Pipelines
- .look
- Curve
- Post.metal
- Furnisher
- FloorPlan
- DebugPanel
- .build
- TraceScene
- Intersect.metal
- ImageIO
- Lift
- related.sh
- VirtualMesh
- RTVoxels
- VGStreamer
- VGParams
- .withUnsafeBufferPointer
- .add
- .cap
- VSM.metal
- BuildingStyleDef
- GPUProfiler
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- SkyImage
- .addFleshCharacter
- Images
- SurfaceKind
- VSMParams
- FoliageRuntimeTests
- uint
- RasterParams
- Role
- BuildingEditorPanel
- PhysicsBody
- VSMInstance
- ColliderGrid
- CrowdHairParams
- PlantTracing
- RasterCounters
- .addHair
- BenchmarkModesTests
- SDFBox
- SDFShape
- CrowdSkinParams
- RagdollTests
- FurnitureItem
- TraversalStats
- XCTestCase
- RasterVGParams
- BVHTests
- SwiftUI
- PhysicsConstraint
- PhysicsGroup
- float4
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
- uint
- SceneShading
- Clip
- LumenParams
- RenderThread
- CharacterBaseTests
- SettingsStore
- SIMD3
- Key
- HairBSDF
- .commit
- .building
- PropLibrary
- RenderPass4
- PhysicsFleshPin
- Double
- WorldPlace
- CameraTrack
- .span
- Launch
- Stage
- PlantEditorPanel
- Core
- WindFrame
- Buffer
- LoadingOverlay
- Kind
- DebugInfo
- LightKind
- .setTexture
- Phyllotaxis
- PhysicsMuscle
- CharacterEditorPanel
- Heavens
- FoliageVoxels
- .encoder
- StressSceneTests
- Kind
- .setBytes
- CharacterMorphs
- .setComputePipelineState
- vsmFragment
- PlantSpecies.swift
- Metal4Backend.swift
- .capture
- Optional
- .useResource
- .updatePrimitives
- Shape

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 599 edges
2. `Scene` - 341 edges
3. `PhysicsWorld` - 275 edges
4. `Renderer` - 271 edges
5. `simd` - 160 edges
6. `SIMD4` - 156 edges
7. `Kernel` - 155 edges
8. `Foliage` - 151 edges
9. `Benchmark` - 129 edges
10. `RenderSettings` - 115 edges

## Surprising Connections (you probably didn't know these)
- `Recipes` --references--> `DemoWalk`  [INFERRED]
  .claude/skills/offscreen/SKILL.md → Sources/MetalRenderer/Benchmark+BuildingsDemo.swift
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal

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

## Communities (270 total, 25 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (52): GLTFModel, .bounds, .triangleCount, Light, GPUEmissiveTriangle, GPUMesh, UInt64, SDFVolume (+44 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.13
Nodes (35): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+27 more)

### Community 3 - "RenderSettings"
Cohesion: 0.07
Nodes (65): Codable, Equatable, Hair, Look, Macro, Float, Cover, UInt32 (+57 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (75): clipSegment(), ggxFromDirection(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular(), LightSubset (+67 more)

### Community 5 - "pcgHash"
Cohesion: 0.07
Nodes (39): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+31 more)

### Community 6 - "CharacterEditorModel"
Cohesion: 0.08
Nodes (23): ObservableObject, CharacterEditorHost, CharacterEditorModel, .dna, .index, .inWorkshop, .isBuiltIn, .isDirty (+15 more)

### Community 7 - "Float"
Cohesion: 0.09
Nodes (25): Level, Float, Bone, Card, Carve, Graft, Grower, LeafRecipe (+17 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.09
Nodes (17): AnyObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key (+9 more)

### Community 11 - "LayerSurface"
Cohesion: 0.11
Nodes (14): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface (+6 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.12
Nodes (20): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, Things that are not structures yet, Where new code belongs, ComputeStage, FrameEncoder, RenderAttachments (+12 more)

### Community 14 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.13
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.18
Nodes (16): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+8 more)

### Community 17 - ".d"
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
Cohesion: 0.04
Nodes (95): Where things are, makeRay(), liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant (+87 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "float4x4"
Cohesion: 0.14
Nodes (15): Parts, GPUMaterial, rotate(), float4x4, Hall, Loop, .length, Props (+7 more)

### Community 24 - "RasterClusters"
Cohesion: 0.11
Nodes (19): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+11 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (60): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+52 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.07
Nodes (32): .cacheURL, CacheFile, Data, URL, CharacterBuilder, CharacterShape, MacroRig, Material (+24 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (136): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+128 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.08
Nodes (26): Settings: `SettingsTable.swift`, NSControl, NSGridView, NSObject, Sides, backToBack, corner, .edges (+18 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (83): To do on the M4 Max, 8. Pipelines and resources, MetalKit, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUPostParams, GPURegirParams (+75 more)

### Community 31 - "Camera"
Cohesion: 0.09
Nodes (13): Darwin, Camera, .forward, .up, Float, CharacterStats, Float, LightMotion (+5 more)

### Community 32 - "CharacterKit"
Cohesion: 0.10
Nodes (22): CharacterKit, .chart, UInt32, Entry, FacePlayer, FaceRig, FaceState, Group (+14 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (31): shadowOrigin(), emptyReservoir(), constant, device, float2, float4, kernel, read (+23 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (46): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+38 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.09
Nodes (33): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams, GPUMuscle (+25 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.11
Nodes (15): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, Data, T (+7 more)

### Community 39 - "Physics.metal"
Cohesion: 0.13
Nodes (58): constant, device, int3, kernel, uint, physActivate(), physCell(), physColourPairs() (+50 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "FaceSculpt"
Cohesion: 0.11
Nodes (18): FaceParts, Material, brows, hair, iris, lips, mouth, pupil (+10 more)

### Community 42 - "String"
Cohesion: 0.03
Nodes (101): MTLBlitCommandEncoder, MTLRenderPassDescriptor, .name, CatalogRegistry, T, FaceExpression, cycle, frown (+93 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.09
Nodes (31): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+23 more)

### Community 45 - "BuildingEditorModel"
Cohesion: 0.04
Nodes (46): Where things are, Encodable, JSONEncoder, BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def (+38 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.16
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.14
Nodes (10): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, Notification, NSWindow, UndoManager (+2 more)

### Community 49 - "Crowd"
Cohesion: 0.12
Nodes (24): .parts, Crowd, .liveStates, Face, Hair, Motion, .isBlend, Part (+16 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 51 - "Float"
Cohesion: 0.12
Nodes (20): Beard, CharacterHair, Flow, back, crown, forward, part, Groom (+12 more)

### Community 52 - "SceneKind"
Cohesion: 0.04
Nodes (44): SceneKind, area, buildings, .cameraFromScene, characters, city, cityNight, cornell (+36 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.07
Nodes (30): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .right (+22 more)

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
Nodes (21): centre, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+13 more)

### Community 60 - "Types.metal"
Cohesion: 0.04
Nodes (53): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+45 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (95): Material, constant, float3, read, SCENE_ACCEL, texture2d, thread, reflectionHitRadiance() (+87 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "InstanceData"
Cohesion: 0.09
Nodes (23): InstanceBlockRef, records, InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1 (+15 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.06
Nodes (26): Float, UnsafeBufferPointer, .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged, MTLResource, Content (+18 more)

### Community 73 - "CityPlan"
Cohesion: 0.09
Nodes (28): WallGrid, .alongX, .hi, .line, .lines, .lo, .middles, Block (+20 more)

### Community 74 - "Int32"
Cohesion: 0.08
Nodes (25): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, LocalIds (+17 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (19): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+11 more)

### Community 77 - "RendererController"
Cohesion: 0.10
Nodes (16): .buildingPlan, .buildingStats, .cameraPosition, .walker, Float, .characterStats, .plantStats, RendererController (+8 more)

### Community 78 - "Int"
Cohesion: 0.04
Nodes (54): MTLRegion, MTLSparseTextureMappingMode, Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer (+46 more)

### Community 79 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.20
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.12
Nodes (14): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled (+6 more)

### Community 83 - "instanceRecord"
Cohesion: 0.08
Nodes (52): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+44 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.14
Nodes (20): Where things are, Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+12 more)

### Community 86 - "LotRef"
Cohesion: 0.08
Nodes (16): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, LotRef, .isWorkshop, .key (+8 more)

### Community 88 - "Capabilities"
Cohesion: 0.20
Nodes (7): Capabilities: `Capabilities.swift`, Capabilities, .summary, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.10
Nodes (24): Card, Skeleton, Foliage, LeafAnchor, LeafShape, blade, kite, needle (+16 more)

### Community 90 - "CharacterDNA"
Cohesion: 0.03
Nodes (65): Group, CharacterDNA, CharacterDNA.Hair, .key, CharacterDNA.Look, CharacterDNA.Macro, CodingKeys, age (+57 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.18
Nodes (10): Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32, UInt8 (+2 more)

### Community 92 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (54): groupElement(), uint4, cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi (+46 more)

### Community 95 - "FluidTests"
Cohesion: 0.09
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (57): crowdHairKernel(), CrowdHairRoot, bary, vertices, CrowdJoint, inverseBindRotation, inverseBindTranslation, local (+49 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.08
Nodes (14): GPUPhysicsGrab, Cloth, Set, HairTests, Float, MTLCommandQueue, MTLDevice, Void (+6 more)

### Community 98 - "Species"
Cohesion: 0.07
Nodes (28): Mesh, RawRepresentable, Age, mature, sapling, young, Part, Plant (+20 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (48): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail, flat (+40 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (39): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBetween(), physBox() (+31 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (19): ArraySlice, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, Float (+11 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (53): uint4, PhysicsCloth, grid, previous, PhysicsJoint, anchorA, anchorB, axisA (+45 more)

### Community 104 - "Rect"
Cohesion: 0.11
Nodes (24): Kind, door, entrance, glazed, lift, open, PlanDoor, PlanRoom (+16 more)

### Community 105 - "CaseIterable"
Cohesion: 0.03
Nodes (79): CaseIterable, Tab, facade, floors, furnish, look, massing, rooms (+71 more)

### Community 106 - "Bool"
Cohesion: 0.07
Nodes (29): Bound, F, .reservoirCount, Bool, .envText, Control, checkbox, custom (+21 more)

### Community 107 - "SkinTextures"
Cohesion: 0.12
Nodes (13): Phases, Marks, .key, SkinAtlas, SkinChart, SkinTextures, .versionKey, Float (+5 more)

### Community 108 - "View"
Cohesion: 0.06
Nodes (65): E, .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body (+57 more)

### Community 109 - "EnvVariable"
Cohesion: 0.05
Nodes (36): SkyMode, atmosphere, constant, image, .title, SettingsEnv, EnvVariable, api (+28 more)

### Community 110 - "RasterScene"
Cohesion: 0.09
Nodes (17): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+9 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (18): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.11
Nodes (20): .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+12 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.10
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 117 - "BuildingAssembler"
Cohesion: 0.17
Nodes (13): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+5 more)

### Community 118 - "Interior"
Cohesion: 0.10
Nodes (26): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+18 more)

### Community 119 - ".buildGallery"
Cohesion: 0.11
Nodes (9): LoadStep, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, SplitMix64, UInt64, MTLCommandQueue (+1 more)

### Community 120 - "MeshSDF"
Cohesion: 0.14
Nodes (14): Int8, Baked, bricks, heights, Heightfield, .hi, MeshSDF, .bytes (+6 more)

### Community 121 - "AABB"
Cohesion: 0.06
Nodes (23): Plant, AABB, .area, .centroid, .isEmpty, Assembly, Bone, Flora (+15 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (14): CodingKey, Keys, hi, lo, Foliage.Curve, Key, crown, linear (+6 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.26
Nodes (5): DemoWalk, Point, Float, SIMD2, BuildingPlan

### Community 126 - ".buildWorld"
Cohesion: 0.14
Nodes (6): BuildingStats, Float, WalkArea, BuildingKit, Float, UInt32

### Community 127 - "BVHBuilder"
Cohesion: 0.18
Nodes (11): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+3 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (42): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+34 more)

### Community 129 - ".load"
Cohesion: 0.17
Nodes (13): CustomStringConvertible, Error, LoadError, unreadable, GLTFError, .description, invalid, unsupported (+5 more)

### Community 130 - "CharacterBase"
Cohesion: 0.07
Nodes (35): Character creator: handoff, Decisions (the user's), Deviations from the plan, and why, Open, Traps found, CharacterBase, Hand, Options (+27 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.11
Nodes (40): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+32 more)

### Community 132 - "PlantCatalog"
Cohesion: 0.09
Nodes (17): .savedDef, PlantCatalog, .count, .covers, File, Foliage.SpeciesDef, .fingerprint, .launch (+9 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "Where things are"
Cohesion: 0.10
Nodes (10): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, Host, PlantEditorTests, URL, Void (+2 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.10
Nodes (11): Benchmark, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture, .shouldRecord (+3 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (36): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+28 more)

### Community 138 - ".pieces"
Cohesion: 0.39
Nodes (6): Piece, SkeletonAtlas, Solid, Float, simd_float3x3, UInt32

### Community 139 - "Map"
Cohesion: 0.10
Nodes (23): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, .megabytes, MTLAccelerationStructure, MTLBuffer (+15 more)

### Community 140 - "BlueNoise"
Cohesion: 0.20
Nodes (7): BlueNoise, SplitMix64, Float, UInt64, URL, CacheTests, URL

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.11
Nodes (35): RasterClusterMeshOut, constant, device, float4, kernel, read, texture2d, thread (+27 more)

### Community 143 - "regirBuildKernel"
Cohesion: 0.11
Nodes (27): quantizeUV(), constant, device, float2, float3, float4, kernel, thread (+19 more)

### Community 144 - ".buildings"
Cohesion: 0.12
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 145 - "RenderView"
Cohesion: 0.09
Nodes (16): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder, CGRect (+8 more)

### Community 146 - ".writeDescriptors"
Cohesion: 0.24
Nodes (5): Tests, float3x3, Float, UInt32, Wind

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.10
Nodes (6): AppKit, Combine, Element, QuartzCore, Array, Headless

### Community 151 - "MeshBuilder"
Cohesion: 0.15
Nodes (12): OptionSet, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+4 more)

### Community 152 - "Pipelines"
Cohesion: 0.08
Nodes (31): ComputePass, MTLComputePipelineState, Step, FluidGPU, .summary, Steps, MTLBuffer, MTLComputePipelineState (+23 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 156 - "Furnisher"
Cohesion: 0.17
Nodes (14): Side, Furnisher, Light, Prefer, any, away, corner, middle (+6 more)

### Community 157 - "FloorPlan"
Cohesion: 0.20
Nodes (7): CGSize, UInt64, FloorPlan, .height, BuildingPlanTests, Float, SIMD2

### Community 158 - "DebugPanel"
Cohesion: 0.08
Nodes (18): NSColor, NSRect, NSStackView, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView (+10 more)

### Community 159 - ".build"
Cohesion: 0.18
Nodes (6): UInt32, UnsafeBufferPointer, MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "ImageIO"
Cohesion: 0.17
Nodes (3): CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "VirtualMesh"
Cohesion: 0.14
Nodes (16): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+8 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "VGStreamer"
Cohesion: 0.12
Nodes (13): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, Set, SIMD2, UInt32 (+5 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (33): constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster, childGroup (+25 more)

### Community 169 - ".withUnsafeBufferPointer"
Cohesion: 0.09
Nodes (19): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Proving a refactor changed nothing, Scorers and other tools (+11 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - ".cap"
Cohesion: 0.25
Nodes (8): Data, Cap, CharacterHairCap, Data, Float, UInt32, URL, BlobWriter

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (22): float3, Light, read, SCENE_ACCEL, texture2d, thread, uint2, write (+14 more)

### Community 173 - "BuildingStyleDef"
Cohesion: 0.07
Nodes (41): Clip, facade, furnish, look, massing, plan, rooms, Clipboard (+33 more)

### Community 174 - "GPUProfiler"
Cohesion: 0.07
Nodes (27): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+19 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.13
Nodes (21): Color, GraphicsContext, FloorPlanView, .body, .help, .picked, .status, .storeys (+13 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "PlantParam"
Cohesion: 0.20
Nodes (8): L, .body, PlantParam, .isInteger, PlantParams, Float, Void, WritableKeyPath

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "SkyImage"
Cohesion: 0.21
Nodes (6): Atmosphere, SkyImage, Float, Set, UnsafeMutableBufferPointer, URL

### Community 181 - ".addFleshCharacter"
Cohesion: 0.06
Nodes (37): GPUSoftVertex, Axis, along, front, up, Flesh, MuscleSpec, Side (+29 more)

### Community 182 - "Images"
Cohesion: 0.11
Nodes (9): 6. Math, A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Modes, Narrowing and overriding, Reading the table (+1 more)

### Community 183 - "SurfaceKind"
Cohesion: 0.12
Nodes (14): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+6 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "uint"
Cohesion: 0.32
Nodes (16): constant, device, float4, kernel, uint, vertex, vsmAllocKernel(), vsmChunksKernel() (+8 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "BuildingEditorPanel"
Cohesion: 0.20
Nodes (7): BuildingEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 190 - "PhysicsBody"
Cohesion: 0.08
Nodes (39): physAcross(), physAnchorTurnWeight(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular, info (+31 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.26
Nodes (8): ColliderGrid, Input, Moving, Float, SIMD2, Walker, .eyePosition, .height

### Community 193 - "CrowdHairParams"
Cohesion: 0.15
Nodes (13): CrowdHairParams, curveBase, firstOffset, firstStrand, followsHead, pad0, pad1, palette (+5 more)

### Community 194 - "PlantTracing"
Cohesion: 0.12
Nodes (19): 7. Acceleration structures and ray tracing, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder (+11 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "SDFShape"
Cohesion: 0.05
Nodes (40): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+32 more)

### Community 200 - "CrowdSkinParams"
Cohesion: 0.15
Nodes (13): CrowdSkinParams, bindBase, currentBase, faceBase, faceScale, faceTargets, firstSlot, groupBase (+5 more)

### Community 201 - "RagdollTests"
Cohesion: 0.18
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.40
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "TraversalStats"
Cohesion: 0.29
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 204 - "XCTestCase"
Cohesion: 0.16
Nodes (6): GLTFLoaderTests, KernelVariantsTests, UInt32, PipelineCacheTests, UInt32, XCTestCase

### Community 205 - "RasterVGParams"
Cohesion: 0.20
Nodes (10): RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad, requestCapacity (+2 more)

### Community 206 - "BVHTests"
Cohesion: 0.27
Nodes (5): BVHTests, Float, StaticString, UInt, UInt64

### Community 207 - "SwiftUI"
Cohesion: 0.22
Nodes (4): PressButton, .body, Void, SwiftUI

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "float4"
Cohesion: 0.05
Nodes (39): float4, physConj(), PhysicsFleshFibre, compliance, g, muscle, pad0, pad1 (+31 more)

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 213 - "SceneBuffersTests"
Cohesion: 0.17
Nodes (7): made, SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "traceKernel"
Cohesion: 0.10
Nodes (53): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+45 more)

### Community 220 - "FBXFile"
Cohesion: 0.07
Nodes (40): Compression, IteratorProtocol, Sequence, simd_double4x4, simd_quatd, Children, Connection, Contents (+32 more)

### Community 221 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 222 - "SceneShading"
Cohesion: 0.12
Nodes (16): MaterialTexture, t, texture2d, texture2d_array, SceneShading, cloudShadow, emissive, feedback (+8 more)

### Community 223 - "Clip"
Cohesion: 0.25
Nodes (7): Clip, graft, habitat, leaves, level, look, Clipboard

### Community 224 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 225 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 227 - "SettingsStore"
Cohesion: 0.18
Nodes (4): base, SettingsStore, Any, DispatchWorkItem

### Community 228 - "SIMD3"
Cohesion: 0.07
Nodes (30): .e, GPUPhysicsShape, .worldToView, PhysicsJoint, PhysicsJointKind, ball, hinge, Float (+22 more)

### Community 229 - "Key"
Cohesion: 0.39
Nodes (5): Hashable, Key, PipelineCache, .count, Value

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".building"
Cohesion: 0.40
Nodes (4): Float, SIMD2, Walker, WalkerTests

### Community 233 - "PropLibrary"
Cohesion: 0.44
Nodes (5): Entry, File, PropLibrary, Float, URL

### Community 234 - "RenderPass4"
Cohesion: 0.17
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState

### Community 235 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 236 - "Double"
Cohesion: 0.11
Nodes (20): Double, World, .anchorTile, .start, Block, City, Flora, Ground (+12 more)

### Community 237 - "WorldPlace"
Cohesion: 0.43
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "CameraTrack"
Cohesion: 0.08
Nodes (17): CameraTrack, .duration, Event, callLift, flashlight, lights, Key, Float (+9 more)

### Community 239 - ".span"
Cohesion: 0.40
Nodes (4): P, BuildingParams, D, WritableKeyPath

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PlantEditorPanel"
Cohesion: 0.24
Nodes (7): PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 244 - "WindFrame"
Cohesion: 0.18
Nodes (9): PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey, PlantTracingTests, MTLCommandQueue (+1 more)

### Community 245 - "Buffer"
Cohesion: 0.25
Nodes (7): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, metal3, metal4, MTLHeap, UInt64

### Community 246 - "LoadingOverlay"
Cohesion: 0.10
Nodes (16): NSFont, NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item (+8 more)

### Community 247 - "Kind"
Cohesion: 0.40
Nodes (5): Kind, beard, brows, lashes, scalp

### Community 248 - "DebugInfo"
Cohesion: 0.25
Nodes (7): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles

### Community 249 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 251 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "CharacterEditorPanel"
Cohesion: 0.21
Nodes (8): NSWindowDelegate, CharacterEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 254 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - "FoliageVoxels"
Cohesion: 0.25
Nodes (11): FoliageVoxels, Grid, Piece, Plant, Float, UInt32, BoxData, MTLCommandQueue (+3 more)

### Community 256 - ".encoder"
Cohesion: 0.23
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 258 - "Kind"
Cohesion: 0.50
Nodes (4): Kind, directional, point, spot

### Community 260 - "CharacterMorphs"
Cohesion: 0.11
Nodes (24): Kind, furniture, glass, solid, stair, Float, Bump, CharacterMorphs (+16 more)

### Community 268 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 271 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 273 - "Optional"
Cohesion: 0.33
Nodes (3): MTLCommandEncoder, Optional, .clipName

### Community 275 - ".updatePrimitives"
Cohesion: 0.20
Nodes (5): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer

### Community 276 - "Shape"
Cohesion: 0.67
Nodes (3): Shape, box, sphere

## Knowledge Gaps
- **1881 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1876 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2506 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **25 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `CharacterEditorModel`, `Float`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `SDFBuffers`, `Metal4Frame`, `translate`, `.d`, `LightTable`, `float4x4`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Camera`, `CharacterKit`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `FaceSculpt`, `String`, `VSMTargets`, `SceneBuffers`, `BuildingEditorModel`, `LumenScene`, `Crowd`, `VirtualGeometry`, `Float`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `Config`, `VirtualTracing`, `CityPlan`, `Int32`, `Metal3Pass`, `RendererController`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Foliage`, `CharacterDNA`, `ProceduralTextures`, `Upscaler`, `FluidTests`, `PhysicsTests`, `Species`, `Building`, `SoftModel`, `Rect`, `CaseIterable`, `Bool`, `SkinTextures`, `View`, `EnvVariable`, `RasterScene`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `.buildGallery`, `MeshSDF`, `AABB`, `BuildingPlan`, `.buildWorld`, `BVHBuilder`, `.load`, `CharacterBase`, `PlantCatalog`, `Benchmark`, `RoomType`, `.pieces`, `Map`, `BlueNoise`, `.writeDescriptors`, `QuartzCore`, `MeshBuilder`, `Pipelines`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `.build`, `Lift`, `VirtualMesh`, `VGStreamer`, `BuildingStyleDef`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `SkyImage`, `.addFleshCharacter`, `Images`, `SurfaceKind`, `FoliageRuntimeTests`, `Role`, `ColliderGrid`, `PlantTracing`, `.addHair`, `SDFShape`, `RagdollTests`, `FurnitureItem`, `TraversalStats`, `XCTestCase`, `BVHTests`, `SceneBuffersTests`, `FBXFile`, `SettingsStore`, `SIMD3`, `Key`, `.commit`, `.building`, `PropLibrary`, `RenderPass4`, `Double`, `WorldPlace`, `CameraTrack`, `.span`, `WindFrame`, `LoadingOverlay`, `Kind`, `DebugInfo`, `LightKind`, `.setTexture`, `Phyllotaxis`, `.encoder`, `StressSceneTests`, `.setBytes`, `CharacterMorphs`, `.updatePrimitives`?**
  _High betweenness centrality (0.283) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `RenderSettings`, `CharacterEditorModel`, `Float`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `translate`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Camera`, `CharacterKit`, `GeneratedCache`, `FaceSculpt`, `SceneBuffers`, `BuildingEditorModel`, `VirtualGeometry`, `Float`, `SceneKind`, `MuscleAtlas`, `Config`, `VirtualTracing`, `RendererController`, `Int`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Capabilities`, `Foliage`, `CharacterDNA`, `Upscaler`, `FluidTests`, `Species`, `Rect`, `CaseIterable`, `Bool`, `SkinTextures`, `View`, `EnvVariable`, `CurveEditor`, `WorldTile`, `.buildGallery`, `AABB`, `Key`, `BuildingPlan`, `.buildWorld`, `.load`, `PlantCatalog`, `Where things are`, `Kind`, `Benchmark`, `RoomType`, `.pieces`, `Map`, `BlueNoise`, `.load`, `Pipelines`, `.look`, `Curve`, `FloorPlan`, `DebugPanel`, `Lift`, `VirtualMesh`, `VGStreamer`, `.add`, `.cap`, `BuildingStyleDef`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `SkyImage`, `.addFleshCharacter`, `Images`, `BenchmarkModesTests`, `TraversalStats`, `XCTestCase`, `BVHTests`, `SwiftUI`, `SceneBuffersTests`, `FBXFile`, `Clip`, `SettingsStore`, `SIMD3`, `.commit`, `PropLibrary`, `Double`, `CameraTrack`, `.span`, `Launch`, `Buffer`, `LoadingOverlay`, `DebugInfo`, `FoliageVoxels`, `.encoder`, `CharacterMorphs`, `.updatePrimitives`?**
  _High betweenness centrality (0.165) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `RenderSettings`, `CharacterEditorModel`, `Float`, `PlantEditorModel`, `LayerSurface`, `FramePlan`, `Metal4Frame`, `translate`, `float4x4`, `RasterClusters`, `SkinnedCharacter`, `SettingsPanel`, `Renderer`, `Camera`, `CharacterKit`, `FaceSculpt`, `String`, `VSMTargets`, `SceneBuffers`, `BuildingEditorModel`, `LumenScene`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `Float`, `SceneKind`, `PhysicsWorld`, `Config`, `VirtualTracing`, `CityPlan`, `Int32`, `RendererController`, `Int`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Foliage`, `Upscaler`, `PhysicsTests`, `Species`, `Building`, `SoftModel`, `Rect`, `SkinTextures`, `View`, `EnvVariable`, `RasterScene`, `WorldTile`, `BuildingAssembler`, `Interior`, `.buildGallery`, `MeshSDF`, `AABB`, `BuildingPlan`, `.buildWorld`, `BVHBuilder`, `CharacterBase`, `PlantCatalog`, `Where things are`, `Benchmark`, `RoomType`, `Map`, `RenderView`, `.writeDescriptors`, `.load`, `MeshBuilder`, `Pipelines`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `Lift`, `VirtualMesh`, `VGStreamer`, `BuildingStyleDef`, `GPUProfiler`, `PlantParam`, `SkyImage`, `.addFleshCharacter`, `SurfaceKind`, `FoliageRuntimeTests`, `BuildingEditorPanel`, `ColliderGrid`, `PlantTracing`, `.addHair`, `SDFShape`, `RagdollTests`, `XCTestCase`, `SwiftUI`, `SceneBuffersTests`, `FBXFile`, `Clip`, `RenderThread`, `SettingsStore`, `SIMD3`, `Key`, `.commit`, `Double`, `CameraTrack`, `PlantEditorPanel`, `Core`, `WindFrame`, `LoadingOverlay`, `DebugInfo`, `LightKind`, `CharacterEditorPanel`, `Heavens`, `FoliageVoxels`, `.encoder`, `.capture`?**
  _High betweenness centrality (0.125) - this node is a cross-community bridge._
- **Are the 58 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 58 INFERRED edges - model-reasoned connections that need verification._
- **Are the 37 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 37 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1881 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.04176370128861978 - nodes in this community are weakly interconnected._