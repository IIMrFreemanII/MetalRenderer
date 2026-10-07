# Graph Report - new-task-7ae158  (2026-10-07)

## Corpus Check
- 203 files · ~1,173,385 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 4)

## Summary
- 5940 nodes · 17828 edges · 238 communities (218 shown, 20 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2651 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0a45a627`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- traceKernel
- .part
- .simplify
- Benchmark
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- .stepStrand
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- flagOn
- Kernel
- SettingsPanel
- Renderer
- String
- pcgHash
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- Mesh
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- .int
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- SIMD4
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- RendererController
- FogParams
- Surface.metal
- RTVoxels
- SceneShading
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
- VirtualBLAS
- simd
- Metal3Pass
- VoxelGrids
- Int
- BVHBuilder
- KernelVariants
- ab.sh
- Post.metal
- LoadActivity
- uint
- EmissiveTriangle
- .load
- World
- Capabilities
- Float
- FoliageTextures
- ProceduralTextures
- SkyParams
- Upscaler
- megaLightsSampleKernel
- FBXFile
- Crowd.metal
- .length
- SIMD3
- Footprint
- float3
- ClusterBox
- SoftBodyTests
- uint4
- Building
- SurfaceMaterial
- EnvVariable
- Types.metal
- PostParams
- MeshData
- Species
- Map
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- .buildCrowd
- RasterScene
- Foliage
- same.sh
- .commit
- baseline.sh
- VoxelLOD
- CityTests
- Int32
- Raster.metal
- RagdollTests
- Slot
- lumenCardRadiosityKernel
- RasterClusters
- PlantWind
- StressSceneTests
- LoadingOverlay
- .init
- .encoder
- RenderPass4
- HairBSDF
- HairTests
- KernelVariantsTests
- RasterClusters.metal
- AABB
- VGStreamer
- .draw
- LayerSurface
- VSMCounters
- SettingsStore
- Hit
- QuartzCore
- MeshBuilder
- Pipelines
- PlantTracing
- Crown
- Metal-only tracer: handoff to the M4 Max (2026-10-06)
- Phyllotaxis
- CameraTrack
- CharacterLibrary
- physCollide
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- .keep
- Float
- .writeDescriptors
- VGParams
- Camera
- PhysicsWorld
- .stages
- VSM.metal
- Double
- .buildStress
- device
- VSMView
- ShadingPoint
- VSMClusterArgs
- VSMScene
- Terrain
- City
- XCTestCase
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SceneBuffersTests
- RasterParams
- .galleryFiles
- SDFBuffers
- PhysicsParams
- VSMInstance
- Buffer
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- GPUMaterial
- SDFBox
- GPU (Metal / MSL) practices for MetalRenderer
- MeshSDF
- SectionHeader
- WindFrame
- SurfaceKind
- PhysicsGrab
- PhysPush
- Shape
- .useResource
- PhysicsConstraint
- PhysicsGroup
- PhysicsHairVertex
- PhysicsPair
- PhysicsPoseParams
- VGRasterInstance
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- Bool
- WorldPlace
- .sampled
- .begin
- Heavens
- .end
- RenderThread
- .meshes
- TraversalStats
- RasterSceneTests
- Section
- VoxelBox
- Measuring MetalRenderer
- RegirParams
- .mark
- VirtualGeometry
- Zone
- Ends
- .bytes

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 322 edges
2. `Scene` - 275 edges
3. `Renderer` - 256 edges
4. `PhysicsWorld` - 190 edges
5. `SIMD4` - 121 edges
6. `Kernel` - 120 edges
7. `.length` - 119 edges
8. `Benchmark` - 105 edges
9. `simd` - 98 edges
10. `RenderSettings` - 97 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift
- `Map` --references--> `Capabilities`  [INFERRED]
  .claude/skills/tests/SKILL.md → Sources/MetalRenderer/Capabilities.swift

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

## Communities (238 total, 20 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (48): simd_float4x4, GPUEmissiveTriangle, GPUInstanceData, GPUMesh, UInt64, .viewNote, BorrowedLight, BorrowedMesh (+40 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (50): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+42 more)

### Community 3 - "RenderSettings"
Cohesion: 0.10
Nodes (35): Codable, Equatable, MTLBuffer, MTLDevice, MTLTexture, Void, CascadeSettings, CitySettings (+27 more)

### Community 4 - "Lights.metal"
Cohesion: 0.06
Nodes (80): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+72 more)

### Community 5 - "traceKernel"
Cohesion: 0.10
Nodes (49): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+41 more)

### Community 6 - ".part"
Cohesion: 0.17
Nodes (15): simd_quatd, FBXError, .description, T, CharacterImporter, concurrently(), Mapping, controlPoint (+7 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Benchmark"
Cohesion: 0.06
Nodes (20): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Render something: `scripts/render.sh`, 6. Math, Modes, Images, Benchmark modes: `Benchmark+Modes.swift`, Benchmark (+12 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "SettingsTable"
Cohesion: 0.08
Nodes (27): Bound, F, .reservoirCount, Control, checkbox, custom, popup, slider (+19 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView (+10 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, 5. Reductions, atomics and threadgroup memory, RC_MAX_CASCADES, constant, device, float3, float4, kernel (+21 more)

### Community 13 - "FramePlan"
Cohesion: 0.19
Nodes (13): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+5 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.08
Nodes (24): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+16 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 16 - "translate"
Cohesion: 0.18
Nodes (15): Scene kinds: `SceneKind` in `Settings.swift`, GPUFogVolume, translate(), FogVolume, .gpu, LightPose, Kit, Float (+7 more)

### Community 17 - ".stepStrand"
Cohesion: 0.08
Nodes (19): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, PhysicsCandidate, .middle, PhysicsManifold, PhysicsShapeKind (+11 more)

### Community 18 - "roundToHalf"
Cohesion: 0.19
Nodes (24): 9. Shader helpers: use them, don't copy, atrousKernel(), depthGradient(), geometryWeights(), constant, float2, float3, float4 (+16 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (75): intersectClosest(), makeRay(), constant, device, float2, float3, float4, kernel (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.09
Nodes (22): MTLRegion, MTLSparseTextureMappingMode, SparseMapping, MTLBuffer, MTLCommandBuffer, MTLHeap, MTLPixelFormat, MTLSize (+14 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (18): simd_double4x4, GPUJoint, .parent, GPUSkinVertex, Clip, .duration, .loopKeys, Level (+10 more)

### Community 27 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (102): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+94 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.15
Nodes (12): Settings: `SettingsTable.swift`, NSControl, NSGridView, FlippedView, .isFlipped, SettingsPanel, .fittedSize, Notification (+4 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (57): 8. Pipelines and resources, SkyImage, Set, done, PreparedScene, Renderer, .accumulating, .activeDirectMode (+49 more)

### Community 31 - "String"
Cohesion: 0.06
Nodes (18): MTLBlitCommandEncoder, MTLRenderPassDescriptor, Frame, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder, SkyMode (+10 more)

### Community 32 - "pcgHash"
Cohesion: 0.07
Nodes (39): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+31 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (46): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+38 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.13
Nodes (23): GPUJointMatrix, GPUMegaLightsParams, GPUPathTraceParams, GPUPhysicsConstraint, GPUPhysicsGrab, GPUPhysicsPair, GPUPhysicsTet, GPURegirReservoir (+15 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (17): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array (+9 more)

### Community 39 - "Physics.metal"
Cohesion: 0.17
Nodes (45): constant, device, int3, kernel, uint, physCell(), physColourPairs(), physColoursAround() (+37 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.14
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (58): CaseIterable, Backend, auto, gpu, .title, DirectLightMode, auto, exact (+50 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (33): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+25 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (31): .empty, LoadOptions, .instanceScratch, RendererError, .description, missingFunction, MTLAccelerationStructure, InstanceBlock (+23 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.17
Nodes (20): constant, device, float2, float3, kernel, thread, uint, regirBuildKernel() (+12 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.15
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, Notification, NSWindow, URL (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - ".int"
Cohesion: 0.40
Nodes (4): invalid, unsupported, T, UnsafeRawBufferPointer

### Community 51 - "DebugPanel"
Cohesion: 0.11
Nodes (12): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, CFTimeInterval, Notification, NSPanel (+4 more)

### Community 52 - "SceneKind"
Cohesion: 0.06
Nodes (34): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+26 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "SIMD4"
Cohesion: 0.13
Nodes (11): GPUPhysicsBody, GPUPhysicsContact, float4x4, PhysicsMath, Float, simd_quatf, Float, Void (+3 more)

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

### Community 59 - "RendererController"
Cohesion: 0.13
Nodes (10): DebugInfo, Float, RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus, Float (+2 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (94): Material, constant, float3, read, SCENE_ACCEL, texture2d, thread, reflectionHitRadiance() (+86 more)

### Community 62 - "RTVoxels"
Cohesion: 0.10
Nodes (20): device, uint3, uint4, RTVoxels, dims, lo, offsets, VGBlas (+12 more)

### Community 63 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.12
Nodes (12): float4x4, Heightfield, .hi, MeshSDFBuilder, Float, SIMD2, UInt32, UnsafeBufferPointer (+4 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (19): .virtualGeometryChanged, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, TraceSceneArgs, VGView (+11 more)

### Community 73 - "CityPlan"
Cohesion: 0.09
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "VirtualBLAS"
Cohesion: 0.14
Nodes (21): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+13 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (17): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+9 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 78 - "Int"
Cohesion: 0.05
Nodes (30): MetalKit, UnsafeRawPointer, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, GPUSkyParams, Float (+22 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.19
Nodes (16): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Key (+8 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 83 - "LoadActivity"
Cohesion: 0.15
Nodes (12): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Snapshot, .isIdle (+4 more)

### Community 84 - "uint"
Cohesion: 0.20
Nodes (23): geometry_type, anyHit(), boxCandidate(), candidate(), candidatePart(), card(), closestDistance(), closestHit() (+15 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.14
Nodes (11): CustomStringConvertible, Error, LoadError, GLTFError, .description, Failure, ShaderSource, URL (+3 more)

### Community 87 - "World"
Cohesion: 0.17
Nodes (10): Flora, Ground, Placement, SplitMix64, UInt32, UInt64, Void, World (+2 more)

### Community 88 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.18
Nodes (14): Card, Carve, Graft, Grower, LeafAnchor, LeafRecipe, Level, Recipe (+6 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (17): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+9 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.17
Nodes (11): heights, Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32 (+3 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FBXFile"
Cohesion: 0.14
Nodes (17): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, FBXFile (+9 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (53): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+45 more)

### Community 97 - ".length"
Cohesion: 0.15
Nodes (7): .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "SIMD3"
Cohesion: 0.08
Nodes (14): Float16, simd_double3x3, Atmosphere, Float, GPURasterMesh, Float, SDFVolume, .hi (+6 more)

### Community 99 - "Footprint"
Cohesion: 0.16
Nodes (12): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .cover (+4 more)

### Community 100 - "float3"
Cohesion: 0.17
Nodes (28): quatRotate(), float3, float4, float4x4, physBetween(), physBox(), physBoxGradient(), physBreeze() (+20 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftBodyTests"
Cohesion: 0.11
Nodes (15): ArraySlice, SoftModel, .radius, Float, float4x4, MeshGeometry, SDFShape, SDFVolume (+7 more)

### Community 103 - "uint4"
Cohesion: 0.05
Nodes (42): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+34 more)

### Community 104 - "Building"
Cohesion: 0.19
Nodes (9): Building, .triangleCount, BuildingGenerator, Module, Data, float4x4, BuildingTests, Float (+1 more)

### Community 105 - "SurfaceMaterial"
Cohesion: 0.09
Nodes (22): Hashable, SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle (+14 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 108 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 110 - "Species"
Cohesion: 0.09
Nodes (23): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+15 more)

### Community 111 - "Map"
Cohesion: 0.13
Nodes (12): Map, BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile (+4 more)

### Community 112 - "WorldTile"
Cohesion: 0.12
Nodes (16): .time, Chunk, .triangles, ChunkRecord, Light, Float, SIMD2, UInt32 (+8 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.11
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (39): physAcross(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular, info, invInertia (+31 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.32
Nodes (9): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+1 more)

### Community 118 - "lumenTraceKernel"
Cohesion: 0.05
Nodes (88): int4, distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams (+80 more)

### Community 119 - ".buildCrowd"
Cohesion: 0.18
Nodes (3): SplitMix64, MeshGeometry, UInt64

### Community 120 - "RasterScene"
Cohesion: 0.22
Nodes (6): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLDevice, MTLTexture

### Community 121 - "Foliage"
Cohesion: 0.13
Nodes (16): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 125 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 127 - "Int32"
Cohesion: 0.05
Nodes (46): Int32, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice (+38 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "RagdollTests"
Cohesion: 0.18
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (50): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+42 more)

### Community 132 - "RasterClusters"
Cohesion: 0.10
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 135 - "LoadingOverlay"
Cohesion: 0.12
Nodes (14): NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item, Row (+6 more)

### Community 136 - ".init"
Cohesion: 0.12
Nodes (13): .isCancelled, LoadStep, .isCancelled, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, Entry (+5 more)

### Community 137 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTLAccelerationStructureCommandEncoder, MTL4ComputeCommandEncoder, MTLBarrierScope

### Community 138 - "RenderPass4"
Cohesion: 0.21
Nodes (5): MTL4RenderCommandEncoder, RenderPass4, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 140 - "HairTests"
Cohesion: 0.21
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 141 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "AABB"
Cohesion: 0.06
Nodes (25): AABB, .area, .centroid, .isEmpty, SDFVolume, Assembly, Bone, Light (+17 more)

### Community 144 - "VGStreamer"
Cohesion: 0.13
Nodes (12): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, SIMD2, UInt32, UnsafePointer (+4 more)

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (25): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+17 more)

### Community 146 - "LayerSurface"
Cohesion: 0.10
Nodes (21): CGSize, Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, NSFont, NSTextField, FrameOutput (+13 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): countedHit(), Hit, barycentrics, cluster, hit, instance, part, primitive (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.17
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - "MeshBuilder"
Cohesion: 0.18
Nodes (10): MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Float, float4x4, MeshGeometry (+2 more)

### Community 152 - "Pipelines"
Cohesion: 0.08
Nodes (28): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, Things that are not structures yet, Where new code belongs, ComputePass, FrameEncoder, PrimitiveWork, .encoderCount, RenderAttachments (+20 more)

### Community 153 - "PlantTracing"
Cohesion: 0.12
Nodes (18): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+10 more)

### Community 154 - "Crown"
Cohesion: 0.29
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "Metal-only tracer: handoff to the M4 Max (2026-10-06)"
Cohesion: 0.50
Nodes (3): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.06
Nodes (23): .current, CameraTrack, .duration, Key, Float, Particles, bubbles, dust (+15 more)

### Community 158 - "CharacterLibrary"
Cohesion: 0.24
Nodes (7): BlobReader, BlobWriter, CharacterLibrary, .directory, Data, T, URL

### Community 159 - "physCollide"
Cohesion: 0.14
Nodes (18): thread, physAdd(), physAddFound(), physAgree(), physArea(), PhysCandidate, n, pa (+10 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.16
Nodes (22): intersection_params, intersection_type, assumeCurves(), assumeCurveShape(), candidateIndex(), commitCurve(), commitCurveCandidate(), committed() (+14 more)

### Community 162 - "AppKit"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - ".keep"
Cohesion: 0.23
Nodes (4): MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLSize

### Community 166 - "Float"
Cohesion: 0.29
Nodes (5): Hall, Loop, Float, float4x4, SIMD2

### Community 167 - ".writeDescriptors"
Cohesion: 0.27
Nodes (6): Tests, float3x3, Float, float4x4, UInt32, Wind

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "Camera"
Cohesion: 0.12
Nodes (14): Darwin, Camera, .forward, .right, .up, .worldToView, rotate(), scale() (+6 more)

### Community 170 - "PhysicsWorld"
Cohesion: 0.07
Nodes (22): GPUPhysicsParams, GPUPhysicsParticle, Cloth, PhysicsJoint, PhysicsJointKind, ball, hinge, PhysicsWorld (+14 more)

### Community 171 - ".stages"
Cohesion: 0.09
Nodes (23): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+15 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "Double"
Cohesion: 0.28
Nodes (3): Double, Highway, Float

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "ShadingPoint"
Cohesion: 0.20
Nodes (10): ShadingPoint, albedo, f0, hair, n, ng, p, roughness (+2 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "Terrain"
Cohesion: 0.28
Nodes (6): Float, SIMD2, UInt32, UInt64, Terrain, .cell

### Community 181 - "City"
Cohesion: 0.26
Nodes (5): Block, City, Road, Roadbeds, SIMD2

### Community 182 - "XCTestCase"
Cohesion: 0.24
Nodes (5): GLTFLoaderTests, PlantTracingTests, MTLCommandQueue, MTLDevice, XCTestCase

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SceneBuffersTests"
Cohesion: 0.22
Nodes (6): SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".galleryFiles"
Cohesion: 0.26
Nodes (3): URL, URL, ShowcaseTests

### Community 189 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 190 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "Buffer"
Cohesion: 0.14
Nodes (11): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLCommandBuffer, MTLHeap (+3 more)

### Community 193 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

### Community 194 - "PhysicsJoint"
Cohesion: 0.20
Nodes (10): physAnchorTurnWeight(), physDampJoint(), PhysicsJoint, anchorA, anchorB, axisA, axisB, info (+2 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "uint"
Cohesion: 0.47
Nodes (10): constant, kernel, uint, vsmAllocKernel(), vsmChunksKernel(), vsmFreeKernel(), vsmResetKernel(), vsmSettleKernel() (+2 more)

### Community 197 - "GPUMaterial"
Cohesion: 0.33
Nodes (7): GPUMaterial, Assembler, Draft, Data, float4x4, UInt8, Void

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.21
Nodes (12): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, GPU (Metal / MSL) practices for MetalRenderer, clusterWalk(), float3 (+4 more)

### Community 200 - "MeshSDF"
Cohesion: 0.17
Nodes (10): Int8, unreadable, Baked, bricks, MeshSDF, .bytes, .cells, .hi (+2 more)

### Community 201 - "SectionHeader"
Cohesion: 0.21
Nodes (7): NSObject, Action, SectionHeader, .expanded, NSCoder, NSStackView, Void

### Community 202 - "WindFrame"
Cohesion: 0.43
Nodes (6): PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 203 - "SurfaceKind"
Cohesion: 0.17
Nodes (12): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+4 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "PhysicsHairVertex"
Cohesion: 0.40
Nodes (5): PhysicsHairVertex, position, previous, rest, velocity

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 213 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "Bool"
Cohesion: 0.17
Nodes (3): Float, Bool, .envText

### Community 220 - "WorldPlace"
Cohesion: 0.27
Nodes (8): Float, SIMD2, World, World, .anchorTile, .start, WorldPlace, .anchor

### Community 221 - ".sampled"
Cohesion: 0.29
Nodes (5): GPUPhysicsShape, SDFShape, ShapeBuild, SDFShape, SDFVolume

### Community 223 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 225 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 226 - ".meshes"
Cohesion: 0.15
Nodes (16): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+8 more)

### Community 227 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 228 - "RasterSceneTests"
Cohesion: 0.31
Nodes (3): RasterSceneTests, Float, MeshGeometry

### Community 229 - "Section"
Cohesion: 0.25
Nodes (5): NSColor, NSStackView, Section, NSCoder, NSView

### Community 230 - "VoxelBox"
Cohesion: 0.29
Nodes (7): VoxelBox, cells, grid, level, pad0, pad1, pad2

### Community 231 - "Measuring MetalRenderer"
Cohesion: 0.33
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 232 - "RegirParams"
Cohesion: 0.33
Nodes (6): float4, uint4, RegirParams, config, consume, origin

### Community 234 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 235 - "Zone"
Cohesion: 0.40
Nodes (5): Zone, factory, garage, office, warehouse

### Community 236 - "Ends"
Cohesion: 0.67
Nodes (3): OptionSet, Ends, Faces

## Knowledge Gaps
- **1359 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1354 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1869 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **20 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.part`, `.simplify`, `Benchmark`, `SettingsTable`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `.stepStrand`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `String`, `RadianceCascades`, `SectionFile`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `.int`, `DebugPanel`, `SceneKind`, `SIMD4`, `RendererController`, `.build`, `VirtualTracing`, `CityPlan`, `VirtualBLAS`, `Metal3Pass`, `VoxelGrids`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `World`, `Float`, `FoliageTextures`, `ProceduralTextures`, `Upscaler`, `FBXFile`, `.length`, `SIMD3`, `Footprint`, `SoftBodyTests`, `Building`, `EnvVariable`, `Species`, `Map`, `WorldTile`, `BuildingAssembler`, `.buildCrowd`, `RasterScene`, `Foliage`, `.commit`, `VoxelLOD`, `CityTests`, `Int32`, `RagdollTests`, `Slot`, `RasterClusters`, `StressSceneTests`, `LoadingOverlay`, `.init`, `.encoder`, `RenderPass4`, `HairTests`, `AABB`, `VGStreamer`, `.draw`, `LayerSurface`, `MeshBuilder`, `Pipelines`, `PlantTracing`, `Phyllotaxis`, `.keep`, `Float`, `.writeDescriptors`, `Camera`, `PhysicsWorld`, `.stages`, `Double`, `.buildStress`, `Terrain`, `City`, `XCTestCase`, `FoliageRuntimeTests`, `SceneBuffersTests`, `SDFBuffers`, `Buffer`, `.addHair`, `GPUMaterial`, `MeshSDF`, `WindFrame`, `SurfaceKind`, `Bool`, `WorldPlace`, `.sampled`, `.meshes`, `TraversalStats`, `RasterSceneTests`, `VirtualGeometry`, `Zone`, `Ends`?**
  _High betweenness centrality (0.321) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `restirGIInitialKernel`, `traceKernel`, `KernelVariantsTests`, `Pipelines`, `flagOn`, `Kernel`?**
  _High betweenness centrality (0.143) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `Raster.metal`, `pcgHash`, `restirGIInitialKernel`, `lumenCardRadiosityKernel`, `Lights.metal`, `device`, `KernelVariants`, `roundToHalf`, `pathTraceKernel`, `LightSampling.metal`, `flagOn`, `Surface.metal`, `Renderer`?**
  _High betweenness centrality (0.124) - this node is a cross-community bridge._
- **Are the 33 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 33 INFERRED edges - model-reasoned connections that need verification._
- **Are the 23 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 23 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 7 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1359 weakly-connected nodes found - possible documentation gaps or missing edges._