# Graph Report - new-task-7ae158  (2026-10-07)

## Corpus Check
- 210 files · ~1,205,642 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6199 nodes · 18885 edges · 231 communities (210 shown, 21 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2840 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `b0cb78cb`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- Hair.metal
- .part
- .simplify
- .addMesh
- evalcommon.py
- Bool
- RenderView
- Shaders.metal
- FramePlan
- GPUProfiler
- Metal4Frame
- .init
- SDFVolume
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- geometryDebugKernel
- Kernel
- SettingsPanel
- Renderer
- LoadingOverlay
- traceKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- Mesh
- String
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- FBXFile
- RendererController
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
- Int
- VoxelGrids
- .planFrame
- BVHBuilder
- Pipelines
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- EmissiveTriangle
- .load
- Double
- Capabilities
- Foliage
- CaseIterable
- SurfaceKind
- SkyParams
- Upscaler
- megaLightsSampleKernel
- Int32
- quatRotate
- .length
- MuscleTests
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- SurfaceMaterial
- EnvVariable
- Types.metal
- PostParams
- MeshData
- Species
- .write
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- SplitMix64
- KernelVariants
- Flora
- same.sh
- Config
- baseline.sh
- PlantTracing
- CityTests
- SDFShape
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- RasterClusters
- PlantWind
- XCTestCase
- LumenMeshSDF
- Benchmark
- .init
- Images
- VoxelLOD
- Metal3Pass
- Map
- RasterClusters.metal
- VGStreamer
- uint
- Measuring MetalRenderer
- LayerSurface
- VSMCounters
- SettingsStore
- Hit
- QuartzCore
- .buildStress
- ComputePass
- LightKind
- Crown
- .vgdebug
- Phyllotaxis
- CameraTrack
- FBXError
- .meshes
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- .used
- RTVoxels
- .createShadingResources
- VGParams
- LumenRadiosityParams
- PhysicsWorld
- MeshSDFBuilderTests
- VSM.metal
- .writeDescriptors
- RasterScene
- device
- VSMView
- .stages
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- InstanceData
- SceneSettings
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- .look
- SDFBuffers
- .buildCrowd
- VSMInstance
- .worldOfRun
- SplitMix
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- LumenSDFHit
- .buildGallery
- RagdollTests
- FoliageVoxels
- Camera
- PhysicsGrab
- PhysPush
- Shape
- .withUnsafeBufferPointer
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- VGRasterInstance
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- .generate
- .roof
- Stage
- RenderThread
- PhysicsSkinAttach
- .begin
- PlantTracingTests
- AABB
- TLASUpdate
- .capture
- WindFrame
- KernelVariantsTests
- Detail

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 379 edges
2. `Scene` - 286 edges
3. `Renderer` - 257 edges
4. `PhysicsWorld` - 232 edges
5. `.length` - 132 edges
6. `SIMD4` - 132 edges
7. `Kernel` - 120 edges
8. `Benchmark` - 108 edges
9. `simd` - 105 edges
10. `RenderSettings` - 97 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
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

## Communities (231 total, 21 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (38): SDFVolume, .viewNote, Assembly, Bone, CityLight, LeafMaterial, LightMotion, animated (+30 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.07
Nodes (53): Buffer, CustomStringConvertible, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable (+45 more)

### Community 3 - "RenderSettings"
Cohesion: 0.09
Nodes (44): Bound, Codable, Equatable, Body, muscles, skin, .title, CascadeSettings (+36 more)

### Community 4 - "Lights.metal"
Cohesion: 0.08
Nodes (67): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+59 more)

### Community 5 - "Hair.metal"
Cohesion: 0.10
Nodes (38): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+30 more)

### Community 6 - ".part"
Cohesion: 0.17
Nodes (12): simd_double4x4, simd_quatd, StaticString, T, CharacterImporter, concurrently(), Part, Skeleton (+4 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - ".addMesh"
Cohesion: 0.10
Nodes (18): GPUEmissiveTriangle, GPUMesh, UInt64, BorrowedLight, BorrowedMesh, Instance, .isGeometry, .isStatic (+10 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "Bool"
Cohesion: 0.07
Nodes (29): F, Bool, .envText, Control, checkbox, custom, popup, slider (+21 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView (+10 more)

### Community 12 - "Shaders.metal"
Cohesion: 0.07
Nodes (43): array, metal_raytracing, metal_stdlib, RC_MAX_CASCADES, glassKernel(), glassReflection(), constant, device (+35 more)

### Community 13 - "FramePlan"
Cohesion: 0.20
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+3 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.07
Nodes (22): MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassDescriptor, MTLTimestamp, Metal3Frame (+14 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.04
Nodes (50): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue, MTL4Compiler, MTL4RenderCommandEncoder, MTL4UpdateSparseTextureMappingOperation (+42 more)

### Community 16 - ".init"
Cohesion: 0.18
Nodes (12): GPUFogVolume, FogVolume, .gpu, LightPose, Kit, Float, Stand, .radius (+4 more)

### Community 17 - "SDFVolume"
Cohesion: 0.17
Nodes (7): Float16, simd_double3x3, SDFVolume, .hi, Float, Float, SDFShape

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.05
Nodes (49): 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns (+41 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (73): constant, device, float2, float3, float4, kernel, Light, read_write (+65 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.10
Nodes (21): MTLRegion, MTLSparseTextureMappingMode, mappings, SparseMapping, MTLCommandBuffer, MTLHeap, MTLPixelFormat, MTLSize (+13 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (16): GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount, SkinnedCharacter (+8 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.12
Nodes (45): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+37 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (103): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+95 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): Settings: `SettingsTable.swift`, NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (53): 8. Pipelines and resources, done, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode, .cameraClusters (+45 more)

### Community 31 - "LoadingOverlay"
Cohesion: 0.10
Nodes (16): NSFont, NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item (+8 more)

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (50): 3. Occupancy and registers: the default suspect for big kernels, hairOrSurface(), groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), laineKarrasPermutation(), luminance() (+42 more)

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
Cohesion: 0.10
Nodes (31): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams, GPUMuscle (+23 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.15
Nodes (11): CryptoKit, MeshGeometry, GeneratedCache, SectionFile, Data, T, UInt32, URL (+3 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.15
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "String"
Cohesion: 0.05
Nodes (48): DirectLightMode, auto, exact, grouped, megalights, restir, .title, LumenTrace (+40 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (36): .empty, LoadOptions, .instanceScratch, .namedInstanceBlocks, RendererError, .description, missingFunction, MTLAccelerationStructure (+28 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.11
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.19
Nodes (11): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+3 more)

### Community 48 - "AppDelegate"
Cohesion: 0.15
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, Notification, NSWindow, URL (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 51 - "RendererController"
Cohesion: 0.04
Nodes (42): The pass, The pass after a feature, The report and the commit message, What to look for, NSColor, NSRect, NSStackView, NSWindowDelegate (+34 more)

### Community 52 - "SceneKind"
Cohesion: 0.06
Nodes (36): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+28 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.11
Nodes (9): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, Float, SIMD8, Void, FleshOptions, Float (+1 more)

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
Nodes (41): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, on (+33 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.04
Nodes (107): Material, ggxFromDirection(), lightSpecular(), ptEval(), constant, device, float3, kernel (+99 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.12
Nodes (17): Int8, float4x4, Baked, bricks, heights, Heightfield, .hi, MeshSDF (+9 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (19): .instanceAS, .virtualGeometryChanged, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, TraceSceneArgs (+11 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (35): .area, Block, CityPlan, Edge, open, party, street, Lamp (+27 more)

### Community 74 - "VirtualBLAS"
Cohesion: 0.14
Nodes (21): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+13 more)

### Community 76 - "Int"
Cohesion: 0.05
Nodes (24): Metal3RenderPass, PrimitiveRefit, RenderPass, MTLAccelerationStructure, MTLBuffer, MTLDepthStencilState, MTLPrimitiveAccelerationStructureDescriptor, MTLRenderCommandEncoder (+16 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (11): MTLResource, BoxData, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32, UInt64 (+3 more)

### Community 78 - ".planFrame"
Cohesion: 0.06
Nodes (24): Error, MetalKit, LoadError, unreadable, SkyImage, Set, GPUPostParams, GPURegirParams (+16 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "Pipelines"
Cohesion: 0.22
Nodes (14): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, Pipelines, .lumen, .rc (+6 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.14
Nodes (12): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Snapshot, .isIdle (+4 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.20
Nodes (27): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+19 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 87 - "Double"
Cohesion: 0.06
Nodes (34): Launch, .summary, Double, HairBSDF, Float, Float, SIMD2, UInt32 (+26 more)

### Community 88 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.18
Nodes (15): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+7 more)

### Community 90 - "CaseIterable"
Cohesion: 0.14
Nodes (17): CaseIterable, CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf (+9 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.19
Nodes (9): AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture, SIMD2, UInt32, Upscaler (+1 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "Int32"
Cohesion: 0.41
Nodes (6): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.09
Nodes (14): GPUPhysicsGrab, translate(), .length, HairTests, Float, MTLCommandQueue, MTLDevice, Void (+6 more)

### Community 98 - "MuscleTests"
Cohesion: 0.16
Nodes (4): MuscleTests, Float, MTLCommandQueue, MTLDevice

### Community 99 - "Footprint"
Cohesion: 0.18
Nodes (10): BuildingGenerator, BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops, Float (+2 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (20): ArraySlice, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, Float (+12 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.23
Nodes (7): Building, Module, Data, float4x4, BuildingTests, Float, SIMD2

### Community 105 - "SurfaceMaterial"
Cohesion: 0.10
Nodes (21): SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle, PlanShape (+13 more)

### Community 106 - "EnvVariable"
Cohesion: 0.08
Nodes (26): EnvVariable, api, denoise, direct, fog, fogSet, gi, .index (+18 more)

### Community 107 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 108 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 110 - "Species"
Cohesion: 0.09
Nodes (23): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+15 more)

### Community 111 - ".write"
Cohesion: 0.13
Nodes (11): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+3 more)

### Community 112 - "WorldTile"
Cohesion: 0.05
Nodes (44): GPUMaterial, Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice (+36 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.12
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.32
Nodes (9): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+1 more)

### Community 118 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 120 - "KernelVariants"
Cohesion: 0.21
Nodes (10): Hashable, KernelVariants, .count, Key, PipelineCache, .count, MTLComputePipelineState, Set (+2 more)

### Community 121 - "Flora"
Cohesion: 0.11
Nodes (15): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 125 - "PlantTracing"
Cohesion: 0.14
Nodes (17): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+9 more)

### Community 127 - "SDFShape"
Cohesion: 0.12
Nodes (23): Node, .transform, Op, intersect, subtract, union, Primitive, box (+15 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "RasterClusters"
Cohesion: 0.10
Nodes (22): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+14 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "XCTestCase"
Cohesion: 0.21
Nodes (5): GLTFLoaderTests, PipelineCacheTests, UInt32, StressSceneTests, XCTestCase

### Community 135 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 136 - "Benchmark"
Cohesion: 0.10
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - ".init"
Cohesion: 0.16
Nodes (12): .isCancelled, LoadStep, .isCancelled, MTLCommandQueue, MTLDevice, MTLTexture, Entry, Level (+4 more)

### Community 138 - "Images"
Cohesion: 0.15
Nodes (3): 6. Math, Modes, Images

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - "Metal3Pass"
Cohesion: 0.11
Nodes (10): Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, MTLHeap, MTLResource (+2 more)

### Community 141 - "Map"
Cohesion: 0.29
Nodes (6): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "VGStreamer"
Cohesion: 0.13
Nodes (12): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, SIMD2, UInt32, UnsafePointer (+4 more)

### Community 144 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 145 - "Measuring MetalRenderer"
Cohesion: 0.29
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 146 - "LayerSurface"
Cohesion: 0.15
Nodes (15): CGSize, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title (+7 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.20
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.08
Nodes (25): OptionSet, Parts, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+17 more)

### Community 152 - "ComputePass"
Cohesion: 0.09
Nodes (24): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, ComputePass, FrameEncoder, RenderAttachments, Float, MTLTexture, SIMD2, UpscaleInputs (+16 more)

### Community 153 - "LightKind"
Cohesion: 0.22
Nodes (9): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+1 more)

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - ".vgdebug"
Cohesion: 0.13
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.10
Nodes (13): CameraTrack, .duration, Key, Float, Particles, bubbles, dust, embers (+5 more)

### Community 158 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 159 - ".meshes"
Cohesion: 0.12
Nodes (17): MTLDevice, Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32 (+9 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "AppKit"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - ".createShadingResources"
Cohesion: 0.14
Nodes (11): 4. CPU↔GPU data layout, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Things that are not structures yet, Where new code belongs, What stays fixed, GPUFogParams, .reflectionPassFlags, GPUSkyParams (+3 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 170 - "PhysicsWorld"
Cohesion: 0.06
Nodes (31): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsShape, Cloth, PhysicsJoint, PhysicsJointKind (+23 more)

### Community 171 - "MeshSDFBuilderTests"
Cohesion: 0.23
Nodes (4): MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - ".writeDescriptors"
Cohesion: 0.27
Nodes (6): Tests, float3x3, Float, float4x4, UInt32, Wind

### Community 174 - "RasterScene"
Cohesion: 0.09
Nodes (18): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+10 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".stages"
Cohesion: 0.17
Nodes (13): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 181 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 182 - "SceneSettings"
Cohesion: 0.13
Nodes (10): Scene kinds: `SceneKind` in `Settings.swift`, SceneSettings, SIMD2, ForestTests, SceneBuffersTests, Float, MeshGeometry, MTLBuffer (+2 more)

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.08
Nodes (25): Atmosphere, Float, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+17 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 189 - "SDFBuffers"
Cohesion: 0.22
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 190 - ".buildCrowd"
Cohesion: 0.21
Nodes (8): Darwin, rotate(), scale(), Float, float4x4, Float, float4x4, Range

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 193 - "SplitMix"
Cohesion: 0.47
Nodes (3): SplitMix, Float, UInt64

### Community 194 - "PhysicsJoint"
Cohesion: 0.25
Nodes (8): PhysicsJoint, anchorA, anchorB, axisA, axisB, info, referenceA, referenceB

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "uint"
Cohesion: 0.47
Nodes (10): constant, kernel, uint, vsmAllocKernel(), vsmChunksKernel(), vsmFreeKernel(), vsmResetKernel(), vsmSettleKernel() (+2 more)

### Community 197 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "LumenSDFHit"
Cohesion: 0.29
Nodes (7): LumenSDFHit, hit, id, local, normal, position, t

### Community 201 - "RagdollTests"
Cohesion: 0.15
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FoliageVoxels"
Cohesion: 0.41
Nodes (7): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32

### Community 203 - "Camera"
Cohesion: 0.20
Nodes (5): Camera, .forward, .right, .up, .worldToView

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 207 - ".withUnsafeBufferPointer"
Cohesion: 0.20
Nodes (6): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), R, Hasher, .array, UnsafeBufferPointer, UnsafeRawBufferPointer

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "float4"
Cohesion: 0.06
Nodes (35): float4, physBetween(), PhysicsFleshFibre, compliance, g, muscle, pad0, pad1 (+27 more)

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

### Community 220 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 221 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 224 - "PlantTracingTests"
Cohesion: 0.36
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 225 - "AABB"
Cohesion: 0.07
Nodes (29): AABB, .area, .centroid, .isEmpty, GPUSoftVertex, .cells, Flesh, MuscleSpec (+21 more)

### Community 226 - "TLASUpdate"
Cohesion: 0.29
Nodes (6): MTL4InstanceAccelerationStructureDescriptor, MTLAccelerationStructureUsage, MTLInstanceAccelerationStructureDescriptor, TLASUpdate, .descriptor, .descriptor4

### Community 227 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 228 - "WindFrame"
Cohesion: 0.43
Nodes (6): PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 230 - "Detail"
Cohesion: 0.67
Nodes (3): Detail, flat, full

## Knowledge Gaps
- **1406 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1401 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1927 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **21 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.part`, `.simplify`, `.addMesh`, `Bool`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `.init`, `SDFVolume`, `GPU (Metal / MSL) practices for MetalRenderer`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `LoadingOverlay`, `RadianceCascades`, `SectionFile`, `Mesh`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `RendererController`, `SceneKind`, `.xyz`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `VirtualBLAS`, `VoxelGrids`, `.planFrame`, `BVHBuilder`, `LoadActivity`, `Double`, `Foliage`, `CaseIterable`, `SurfaceKind`, `Upscaler`, `Int32`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `Species`, `.write`, `WorldTile`, `BuildingAssembler`, `SplitMix64`, `KernelVariants`, `Flora`, `Config`, `PlantTracing`, `CityTests`, `SDFShape`, `SettingsTableTests`, `Slot`, `RasterClusters`, `XCTestCase`, `Benchmark`, `.init`, `Images`, `VoxelLOD`, `Metal3Pass`, `VGStreamer`, `LayerSurface`, `.buildStress`, `ComputePass`, `LightKind`, `Phyllotaxis`, `FBXError`, `.meshes`, `.used`, `.createShadingResources`, `PhysicsWorld`, `MeshSDFBuilderTests`, `.writeDescriptors`, `RasterScene`, `.stages`, `LumenGlobalSDF`, `SceneSettings`, `FoliageRuntimeTests`, `SIMD3`, `SDFBuffers`, `.buildCrowd`, `.buildGallery`, `RagdollTests`, `FoliageVoxels`, `.roof`, `PlantTracingTests`, `AABB`, `TLASUpdate`, `WindFrame`, `Detail`?**
  _High betweenness centrality (0.335) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `.createShadingResources`, `KernelVariants`, `Kernel`?**
  _High betweenness centrality (0.158) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `RenderSettings`, `.part`, `.simplify`, `.addMesh`, `RenderView`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `.init`, `TextureStreamer`, `VirtualGeometry`, `SettingsPanel`, `Renderer`, `LoadingOverlay`, `Mesh`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `AppDelegate`, `Crowd`, `RendererController`, `SceneKind`, `.xyz`, `.build`, `VirtualTracing`, `CityPlan`, `VirtualBLAS`, `Int`, `.planFrame`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `.load`, `Double`, `Foliage`, `CaseIterable`, `SurfaceKind`, `Upscaler`, `Int32`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `Species`, `WorldTile`, `BuildingAssembler`, `KernelVariants`, `Flora`, `Config`, `PlantTracing`, `CityTests`, `SDFShape`, `SettingsTableTests`, `RasterClusters`, `XCTestCase`, `Benchmark`, `.init`, `VoxelLOD`, `VGStreamer`, `LayerSurface`, `.buildStress`, `ComputePass`, `LightKind`, `FBXError`, `.meshes`, `.createShadingResources`, `PhysicsWorld`, `.writeDescriptors`, `RasterScene`, `LumenGlobalSDF`, `SceneSettings`, `FoliageRuntimeTests`, `SIMD3`, `.buildCrowd`, `RagdollTests`, `FoliageVoxels`, `Shape`, `.roof`, `RenderThread`, `AABB`, `TLASUpdate`, `.capture`, `WindFrame`?**
  _High betweenness centrality (0.114) - this node is a cross-community bridge._
- **Are the 36 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 36 INFERRED edges - model-reasoned connections that need verification._
- **Are the 23 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 23 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 7 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1406 weakly-connected nodes found - possible documentation gaps or missing edges._