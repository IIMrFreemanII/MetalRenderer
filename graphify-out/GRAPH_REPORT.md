# Graph Report - graphify-update-4183f9  (2026-10-07)

## Corpus Check
- 207 files · ~1,199,912 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6099 nodes · 18557 edges · 224 communities (205 shown, 19 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2794 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `2249bc97`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Equatable
- Lights.metal
- traceKernel
- .part
- .simplify
- DebugPanel
- evalcommon.py
- RenderSettings
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- SDFVolume
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamWork
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- geometryDebugKernel
- Kernel
- SettingsPanel
- Renderer
- DebugInfo
- reflectionKernel
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
- Surface.metal
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
- RenderPass
- VoxelGrids
- Int
- BVHBuilder
- .compile
- ab.sh
- Post.metal
- LumenSDF.metal
- Ray
- EmissiveTriangle
- .load
- Double
- Capabilities
- Float
- FoliageTextures
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
- PhysicsWorld
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
- Foliage
- same.sh
- .commit
- baseline.sh
- PlantTracing
- CityTests
- SDFShape
- Raster.metal
- Custom
- Slot
- lumenCardRadiosityKernel
- RasterClusters
- PlantWind
- StressSceneTests
- LumenMeshSDF
- Benchmark
- TextureStreamer
- RenderPass4
- HairBSDF
- HairTests
- Map
- RasterClusters.metal
- VGStreamer
- uint
- .draw
- String
- VSMCounters
- SettingsStore
- Hit
- QuartzCore
- .buildStress
- Pipelines
- LightKind
- Crown
- Metal-only tracer: handoff to the M4 Max (2026-10-06)
- Phyllotaxis
- Particles
- CharacterLibrary
- VirtualMesh
- TraceScene
- Intersect.metal
- ImageIO
- RasterVGParams
- related.sh
- .used
- RTVoxels
- FleshFigure
- VGParams
- LumenRadiosityParams
- Float
- .points
- VSM.metal
- RegirParams
- Camera
- device
- VSMView
- .useResource
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
- XCTestCase
- SDFBuffers
- Offscreen rendering in MetalRenderer
- VSMInstance
- Buffer
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- LumenSDFHit
- .meshes
- PhysicsGrab
- PhysPush
- Shape
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
- Bool
- Stage
- RenderThread
- PhysicsSkinAttach
- .rasterResources
- .end
- AABB
- LightMotion
- Side

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 379 edges
2. `Scene` - 284 edges
3. `Renderer` - 253 edges
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

## Communities (224 total, 19 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (32): GPUEmissiveTriangle, meshLights, .viewNote, BorrowedLight, CityLight, CurveMesh, Instance, .isGeometry (+24 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (50): Buffer, CustomStringConvertible, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable (+42 more)

### Community 3 - "Equatable"
Cohesion: 0.16
Nodes (30): Bound, Codable, Equatable, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel (+22 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (74): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+66 more)

### Community 5 - "traceKernel"
Cohesion: 0.10
Nodes (49): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+41 more)

### Community 6 - ".part"
Cohesion: 0.17
Nodes (15): simd_quatd, FBXError, .description, CharacterImporter, concurrently(), Mapping, controlPoint, polygonVertex (+7 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "DebugPanel"
Cohesion: 0.14
Nodes (8): NSWindowDelegate, DebugPanel, .wasVisible, CFTimeInterval, Notification, NSPanel, NSTextField, NSWindow

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "RenderSettings"
Cohesion: 0.07
Nodes (24): Settings: `SettingsTable.swift`, Things that are not structures yet, Where new code belongs, F, on, RenderSettings, SettingsEnv, Control (+16 more)

### Community 11 - "RenderView"
Cohesion: 0.07
Nodes (19): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, NSView, InputHandler (+11 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.11
Nodes (33): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Performance in MetalRenderer, The loop, RC_MAX_CASCADES, constant (+25 more)

### Community 13 - "FramePlan"
Cohesion: 0.13
Nodes (18): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, ComputeStage, FrameEncoder, RenderAttachments, Uniforms, Void (+10 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.07
Nodes (23): 1. Frame structure and submission, MTLBlitCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLRenderPassDescriptor (+15 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.10
Nodes (19): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, MTLStages (+11 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (17): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, GPUFogVolume, scale(), translate(), FogVolume, .gpu, LightPose (+9 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

### Community 18 - "roundToHalf"
Cohesion: 0.14
Nodes (30): 10. GPU tools, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, atrousKernel() (+22 more)

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

### Community 23 - "TextureStreamWork"
Cohesion: 0.14
Nodes (12): MTLRegion, MTLSparseTextureMappingMode, mappings, SparseMapping, MTLCommandBuffer, MTLPixelFormat, MTLSize, MTLTexture (+4 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (58): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+50 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (18): simd_double4x4, GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount (+10 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (103): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+95 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (56): 8. Pipelines and resources, LoadOptions, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode, .cameraClusters (+48 more)

### Community 31 - "DebugInfo"
Cohesion: 0.12
Nodes (12): DebugInfo, FlippedView, .isFlipped, FrameGraphView, Float, NSView, VirtualGeometry, blas (+4 more)

### Community 32 - "reflectionKernel"
Cohesion: 0.06
Nodes (57): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+49 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (32): lightSampleTarget(), shadowOrigin(), emptyReservoir(), constant, device, float2, float4, kernel (+24 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.19
Nodes (11): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+3 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.12
Nodes (27): simd_float4x4, GPUFleshFibre, GPUFleshPin, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams, GPUPathTraceParams, GPUPhysicsConstraint (+19 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (19): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, Stored, .array (+11 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.14
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (66): CaseIterable, Backend, auto, gpu, .title, Body, muscles, skin (+58 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (38): MTLDevice, .empty, RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLDevice, MTLTexture (+30 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.16
Nodes (20): constant, device, float2, float3, kernel, thread, uint, regirBuildKernel() (+12 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (8): NSApplication, NSApplicationDelegate, AppDelegate, Any, Notification, NSWindow, URL, NSWindow

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - "FBXFile"
Cohesion: 0.13
Nodes (17): IteratorProtocol, Sequence, Children, Connection, Contents, invalid, unsupported, FBXFile (+9 more)

### Community 51 - "RendererController"
Cohesion: 0.15
Nodes (9): RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus, Float, NSEvent, SIMD2 (+1 more)

### Community 52 - "SceneKind"
Cohesion: 0.04
Nodes (42): MTLBuffer, MTLDevice, MTLTexture, Void, SceneKind, area, .cameraFromScene, city (+34 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.08
Nodes (15): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsJoint, GPUPhysicsParams, PhysicsJoint, Float, SIMD8, Void (+7 more)

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
Cohesion: 0.08
Nodes (37): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+29 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (86): Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+78 more)

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
Cohesion: 0.11
Nodes (17): Int8, float4x4, Baked, bricks, heights, Heightfield, .hi, MeshSDF (+9 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.07
Nodes (25): .instanceAS, .virtualGeometryChanged, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64 (+17 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "VirtualBLAS"
Cohesion: 0.14
Nodes (21): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+13 more)

### Community 76 - "RenderPass"
Cohesion: 0.07
Nodes (16): MTL4InstanceAccelerationStructureDescriptor, Metal3RenderPass, PrimitiveRefit, RenderPass, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLDepthStencilState (+8 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 78 - "Int"
Cohesion: 0.05
Nodes (29): MetalKit, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, GPUSkyParams, Float, UnsafeBufferPointer (+21 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - ".compile"
Cohesion: 0.31
Nodes (9): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, .function, AnyObject, MTLDevice, MTLPixelFormat, MTLRenderPipelineState (+1 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

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
Cohesion: 0.18
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 87 - "Double"
Cohesion: 0.08
Nodes (30): Double, Float, SIMD2, UInt32, UInt64, Terrain, .cell, Block (+22 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.18
Nodes (14): Card, Carve, Graft, Grower, LeafAnchor, LeafRecipe, Level, Recipe (+6 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.12
Nodes (14): Float, MTLTexture, Range, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer (+6 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "Int32"
Cohesion: 0.26
Nodes (10): Compression, FBXArrayElement, Float, Int32, Int64, LocalIds, MeshClusterizer, Float (+2 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "MuscleTests"
Cohesion: 0.10
Nodes (10): GPUFleshHeader, UInt32, UInt32, Group, MTLDevice, UInt32, MuscleTests, Float (+2 more)

### Community 99 - "Footprint"
Cohesion: 0.15
Nodes (13): BuildingGenerator, BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint (+5 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "PhysicsWorld"
Cohesion: 0.06
Nodes (39): ArraySlice, GPUMuscle, GPUPhysicsParticle, GPUPhysicsTet, GPUSoftVertex, PhysicsWorld, .buckets, .cellSize (+31 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.23
Nodes (8): Building, Module, Data, float4x4, made, BuildingTests, Float, SIMD2

### Community 105 - "SurfaceMaterial"
Cohesion: 0.09
Nodes (22): Hashable, SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle (+14 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "Types.metal"
Cohesion: 0.20
Nodes (9): MaterialTexture, t, texture2d, uint, rayClass(), RegirParams, RegirReservoir, VSMScene (+1 more)

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
Cohesion: 0.07
Nodes (34): GPUMaterial, .time, Float, SIMD2, World, World, .anchorTile, .start (+26 more)

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
Cohesion: 0.38
Nodes (6): KernelVariants, .count, Key, MTLComputePipelineState, Set, UInt32

### Community 121 - "Foliage"
Cohesion: 0.13
Nodes (16): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 125 - "PlantTracing"
Cohesion: 0.05
Nodes (45): Tests, float3x3, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart (+37 more)

### Community 127 - "SDFShape"
Cohesion: 0.09
Nodes (30): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+22 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "Custom"
Cohesion: 0.20
Nodes (10): Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, showcaseModel, skyImage (+2 more)

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "RasterClusters"
Cohesion: 0.10
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 135 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 136 - "Benchmark"
Cohesion: 0.05
Nodes (29): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Render something: `scripts/render.sh`, What headless changes, and what it doesn't, 6. Math, Modes, Reading the table, Images, Benchmark modes: `Benchmark+Modes.swift` (+21 more)

### Community 137 - "TextureStreamer"
Cohesion: 0.18
Nodes (14): Entry, Level, Data, MTLCommandQueue, MTLDevice, MTLHeap, UInt32, URL (+6 more)

### Community 138 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 140 - "HairTests"
Cohesion: 0.23
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 141 - "Map"
Cohesion: 0.11
Nodes (11): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, MTLCommandQueue, MTLDevice (+3 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "VGStreamer"
Cohesion: 0.13
Nodes (12): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, SIMD2, UInt32, UnsafePointer (+4 more)

### Community 144 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (25): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants (+17 more)

### Community 146 - "String"
Cohesion: 0.05
Nodes (32): CGSize, Error, NSColor, NSStackView, LoadError, unreadable, SkyImage, Set (+24 more)

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
Cohesion: 0.18
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (25): OptionSet, Parts, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+17 more)

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (26): ComputePass, Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, MTLHeap (+18 more)

### Community 153 - "LightKind"
Cohesion: 0.22
Nodes (9): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+1 more)

### Community 154 - "Crown"
Cohesion: 0.29
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "Metal-only tracer: handoff to the M4 Max (2026-10-06)"
Cohesion: 0.40
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 158 - "CharacterLibrary"
Cohesion: 0.28
Nodes (6): BlobReader, BlobWriter, CharacterLibrary, .directory, Data, URL

### Community 159 - "VirtualMesh"
Cohesion: 0.14
Nodes (16): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+8 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "ImageIO"
Cohesion: 0.26
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

### Community 167 - "FleshFigure"
Cohesion: 0.11
Nodes (16): .cells, Axis, along, front, up, Bone, FleshFigure, Float (+8 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 170 - "Float"
Cohesion: 0.15
Nodes (8): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, UnsafeBufferPointer

### Community 171 - ".points"
Cohesion: 0.46
Nodes (3): SplitMix, Float, UInt64

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "RegirParams"
Cohesion: 0.33
Nodes (6): float4, uint4, RegirParams, config, consume, origin

### Community 174 - "Camera"
Cohesion: 0.10
Nodes (14): Camera, .forward, .right, .up, .worldToView, rotate(), Float, float4x4 (+6 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.06
Nodes (32): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLTexture (+24 more)

### Community 181 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 182 - "SceneSettings"
Cohesion: 0.08
Nodes (11): SceneSettings, SIMD2, PlantTracingTests, MTLCommandQueue, MTLDevice, SceneBuffersTests, Float, MeshGeometry (+3 more)

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.06
Nodes (34): Atmosphere, Float, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsShape, GPURasterMesh (+26 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "XCTestCase"
Cohesion: 0.15
Nodes (5): URL, ForestTests, GLTFLoaderTests, ShowcaseTests, XCTestCase

### Community 189 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 190 - "Offscreen rendering in MetalRenderer"
Cohesion: 0.50
Nodes (3): Offscreen rendering in MetalRenderer, Recipes, Rules

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "Buffer"
Cohesion: 0.17
Nodes (10): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, metal3, metal4, MTLCommandBuffer, MTLHeap, MTLTexture (+2 more)

### Community 193 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

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

### Community 200 - ".meshes"
Cohesion: 0.12
Nodes (7): GLTFModel, .bounds, .triangleCount, GPUMesh, UInt64, MeshGeometry, URL

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

### Community 219 - "Bool"
Cohesion: 0.18
Nodes (4): Ends, Float, Bool, .envText

### Community 220 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 221 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 225 - "AABB"
Cohesion: 0.08
Nodes (25): AABB, .area, .centroid, .isEmpty, SDFVolume, Assembly, Bone, BorrowedMesh (+17 more)

### Community 226 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 227 - "Side"
Cohesion: 0.50
Nodes (4): Side, back, front, out

## Knowledge Gaps
- **1395 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1390 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1910 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **19 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Equatable`, `.part`, `.simplify`, `DebugPanel`, `RenderSettings`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `TextureStreamWork`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `DebugInfo`, `RadianceCascades`, `SectionFile`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `RendererController`, `SceneKind`, `.xyz`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `VirtualBLAS`, `RenderPass`, `VoxelGrids`, `BVHBuilder`, `Double`, `Float`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `Int32`, `.length`, `MuscleTests`, `Footprint`, `PhysicsWorld`, `Building`, `EnvVariable`, `Species`, `.write`, `WorldTile`, `BuildingAssembler`, `SplitMix64`, `KernelVariants`, `Foliage`, `.commit`, `PlantTracing`, `CityTests`, `SDFShape`, `Slot`, `RasterClusters`, `StressSceneTests`, `Benchmark`, `TextureStreamer`, `RenderPass4`, `HairTests`, `VGStreamer`, `String`, `.buildStress`, `Pipelines`, `LightKind`, `Phyllotaxis`, `VirtualMesh`, `.used`, `FleshFigure`, `Float`, `.points`, `Camera`, `LumenGlobalSDF`, `SceneSettings`, `FoliageRuntimeTests`, `SIMD3`, `SDFBuffers`, `Buffer`, `.addHair`, `.meshes`, `Bool`, `.rasterResources`, `AABB`?**
  _High betweenness centrality (0.345) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `.compile` to `reflectionKernel`, `restirGIInitialKernel`, `traceKernel`, `RenderSettings`, `Map`, `KernelVariants`, `Kernel`, `Pipelines`?**
  _High betweenness centrality (0.141) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `reflectionKernel`, `Raster.metal`, `restirGIInitialKernel`, `lumenCardRadiosityKernel`, `Lights.metal`, `device`, `.compile`, `roundToHalf`, `Ray`, `LightSampling.metal`, `Surface.metal`, `Renderer`?**
  _High betweenness centrality (0.112) - this node is a cross-community bridge._
- **Are the 36 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 36 INFERRED edges - model-reasoned connections that need verification._
- **Are the 22 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 22 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1395 weakly-connected nodes found - possible documentation gaps or missing edges._