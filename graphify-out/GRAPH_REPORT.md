# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 230 files · ~1,270,104 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6993 nodes · 21453 edges · 252 communities (233 shown, 19 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3291 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `8e469178`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- Hair.metal
- .simplify
- Fluid.metal
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- ParticleSystem
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- Int
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- flagOn
- Kernel
- SettingsPanel
- Renderer
- ParticlesGPU
- traceKernel
- restirSpatialKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- .write
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- .part
- RendererController
- SceneKind
- 3D Geometric Test Scene
- SIMD3
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Surface.metal
- SDFBox
- MeshData
- Direct Rendering Stress Test 32
- AABB
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- Rect
- FluidSystem
- simd
- Metal3Pass
- RasterClusters
- LoadingOverlay
- BVHBuilder
- Pipelines
- ab.sh
- LoadActivity
- LumenSDF.metal
- uint
- VirtualBLAS
- GPULight
- Double
- Capabilities
- Float
- FoliageTextures
- SurfaceKind
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- MuscleTests
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- BuildingStyle
- EnvVariable
- ParticleTests
- CameraTrack
- Benchmark
- Species
- .write
- Chunk
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- .meshes
- HairTests
- Foliage
- same.sh
- PhysicsWorld
- baseline.sh
- VGStreamer
- CityPlan
- .addFleshCharacter
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- XCTestCase
- ParticleEmitter
- Config
- .encodeSceneUpdate
- SIMD4
- VoxelLOD
- VirtualMesh
- FluidSurface.metal
- RasterClusters.metal
- Shaders.metal
- Bool
- .draw
- LayerSurface
- VSMCounters
- Particles.metal
- LumenCards
- QuartzCore
- .buildStress
- ComputePass
- .trees
- Crown
- .vgdebug
- Phyllotaxis
- Stage
- FBXError
- FBXFile
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- RasterInstance
- RTVoxels
- Post.metal
- VGParams
- float3
- .look
- .begin
- VSM.metal
- dot
- GPUMesh
- device
- VSMView
- .clusterize
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- SceneShading
- SceneBuffersTests
- SkyParams
- VSMParams
- FoliageVoxels
- .length
- RasterParams
- BenchmarkModesTests
- PipelineCache
- ParticleCounts
- VSMInstance
- PostParams
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SettingsStore
- float4
- .init
- RagdollTests
- WorldTile
- String
- PhysicsGrab
- PhysPush
- Buffer
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- float4
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- ParticleStep
- Particles: handoff (branch claude/init-branch-94ae07)
- RasterScene
- PhysicsSkinAttach
- Camera
- LightKind
- SkinShell
- .encoder
- .capture
- Types.metal
- KernelVariantsTests
- HairBSDF
- .commit
- .updatePrimitives
- .checkPool
- RenderPass4
- Shape
- Heavens
- WorldPlace
- SplitMix64
- boxCandidate
- constant
- ParticlesCPU
- VGBlas
- .testTheCutsBLASHoldsTheCutsTriangles
- .mark
- .useResource
- Particles
- .end
- .load
- VGRasterInstance
- .worldView
- LightMotion

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 442 edges
2. `Scene` - 304 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 263 edges
5. `Kernel` - 165 edges
6. `SIMD4` - 161 edges
7. `.length` - 160 edges
8. `simd` - 117 edges
9. `Benchmark` - 111 edges
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

## Communities (252 total, 19 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (52): GPUEmissiveTriangle, SDFVolume, .viewNote, Assembly, Bone, BorrowedLight, BorrowedMesh, CityLight (+44 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.05
Nodes (56): Buffer, CustomStringConvertible, Decodable, Decoder, Error, Node, Primitive, Accessor (+48 more)

### Community 3 - "RenderSettings"
Cohesion: 0.13
Nodes (34): Codable, Equatable, ParticleEmitter, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel (+26 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (79): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+71 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.08
Nodes (58): half4, float2, float3, float4, primitive_acceleration_structure, read, SCENE_ACCEL, texture2d (+50 more)

### Community 6 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

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
Cohesion: 0.14
Nodes (28): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+20 more)

### Community 13 - "FramePlan"
Cohesion: 0.10
Nodes (29): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, Things that are not structures yet, Where new code belongs, MetalKit, ComputeStage, FrameEncoder (+21 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.09
Nodes (17): 1. Frame structure and submission, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+9 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 16 - "translate"
Cohesion: 0.14
Nodes (24): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, rotate(), scale(), Float, float4x4, translate(), FogVolume (+16 more)

### Community 17 - "ParticleSystem"
Cohesion: 0.07
Nodes (29): GPUParticleCollider, Flags, Orientation, axis, .code, rayFacing, velocity, world (+21 more)

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.15
Nodes (28): 10. GPU tools, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, atrousKernel() (+20 more)

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
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "Int"
Cohesion: 0.06
Nodes (32): MTLRegion, MTLSparseTextureMappingMode, Range, RestirTargets, MTLResource, Int, .envText, Entry (+24 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (19): simd_double4x4, GPUJoint, .parent, GPUJointMatrix, Clip, .duration, .loopKeys, Level (+11 more)

### Community 27 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (147): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+139 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): Settings: `SettingsTable.swift`, NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (69): 8. Pipelines and resources, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, GPUSkyParams, done, FogTargets (+61 more)

### Community 31 - "ParticlesGPU"
Cohesion: 0.12
Nodes (19): Part, Build, Counter, Part, ParticlesGPU, .trailShape, Float, MTL4ComputeCommandEncoder (+11 more)

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (48): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), laineKarrasPermutation(), luminance(), makeSampler() (+40 more)

### Community 33 - "restirSpatialKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.11
Nodes (32): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUMegaLightsParams, GPUMuscle (+24 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.09
Nodes (20): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, Stored (+12 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.12
Nodes (19): Card, Plant, Skeleton, LeafAnchor, LeafShape, blade, kite, needle (+11 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (63): CaseIterable, CityStyle, mixed, modern, office, oldtown, residential, .title (+55 more)

### Community 43 - "VSMTargets"
Cohesion: 0.05
Nodes (44): GPUVSMView, Kind, arrays, block, clusters, skip, virtual, Node (+36 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.04
Nodes (62): Map, .empty, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart (+54 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.12
Nodes (10): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindow, AppDelegate, Any, Notification, NSWindow (+2 more)

### Community 49 - "Crowd"
Cohesion: 0.12
Nodes (20): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+12 more)

### Community 50 - ".part"
Cohesion: 0.22
Nodes (10): simd_quatd, StaticString, .layerCount, CharacterImporter, concurrently(), Skeleton, .bindPositions, .bindRotations (+2 more)

### Community 51 - "RendererController"
Cohesion: 0.05
Nodes (32): NSWindowDelegate, DebugInfo, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval (+24 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (37): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+29 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "SIMD3"
Cohesion: 0.07
Nodes (22): Atmosphere, LoadError, unreadable, SkyImage, Float, Set, Int32, Bone (+14 more)

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
Nodes (43): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+35 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (95): Material, constant, float3, read, SCENE_ACCEL, texture2d, thread, reflectionHitRadiance() (+87 more)

### Community 62 - "SDFBox"
Cohesion: 0.10
Nodes (21): device, SDFBox, pad0, pad1, pad2, pad3, scene, shape (+13 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "AABB"
Cohesion: 0.07
Nodes (26): Int8, AABB, .area, .centroid, .isEmpty, float4x4, Baked, bricks (+18 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.05
Nodes (32): Float, UnsafeBufferPointer, MTLComputePipelineState, .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged, Content (+24 more)

### Community 73 - "Rect"
Cohesion: 0.11
Nodes (18): .area, Ends, Float, Block, Lamp, Lot, .front, .size (+10 more)

### Community 74 - "FluidSystem"
Cohesion: 0.11
Nodes (20): .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, Pose, FluidSystem (+12 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (19): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+11 more)

### Community 77 - "RasterClusters"
Cohesion: 0.11
Nodes (20): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+12 more)

### Community 78 - "LoadingOverlay"
Cohesion: 0.12
Nodes (14): NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item, Row (+6 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.13
Nodes (14): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+6 more)

### Community 80 - "Pipelines"
Cohesion: 0.17
Nodes (20): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Key (+12 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.14
Nodes (11): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Snapshot, .isIdle (+3 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "uint"
Cohesion: 0.12
Nodes (34): candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart() (+26 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.14
Nodes (20): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+12 more)

### Community 86 - "GPULight"
Cohesion: 0.16
Nodes (12): GPULight, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2, UInt32 (+4 more)

### Community 87 - "Double"
Cohesion: 0.18
Nodes (13): Double, World, .anchorTile, .start, Block, City, Ground, Highway (+5 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.17
Nodes (13): Card, Carve, Graft, Grower, LeafRecipe, Level, Recipe, Skeleton (+5 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.10
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "ParticleTextures"
Cohesion: 0.10
Nodes (23): Kind, Aux, flameMotion, .layer, smokeBack, smokeLight, Kind, bubble (+15 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.10
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.12
Nodes (7): GPUPhysicsGrab, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "MuscleTests"
Cohesion: 0.16
Nodes (4): MuscleTests, Float, MTLCommandQueue, MTLDevice

### Community 99 - "Footprint"
Cohesion: 0.14
Nodes (14): BuildingTier, .top, Footprint, .cover, .loops, Shape, courtyard, l (+6 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.07
Nodes (30): ArraySlice, GPUSoftEmbed, GPUSoftVertex, Flesh, FleshOptions, MuscleSpec, Side, back (+22 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.12
Nodes (17): Building, .triangleCount, BuildingGenerator, BuildingSpec, Detail, flat, full, Module (+9 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "ParticleTests"
Cohesion: 0.17
Nodes (8): GPUParticle, Float, UInt64, ParticleTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 108 - "CameraTrack"
Cohesion: 0.11
Nodes (7): CameraTrack, .duration, Key, Float, ShowcaseLook, Float, Void

### Community 109 - "Benchmark"
Cohesion: 0.10
Nodes (13): 6. Math, Modes, Images, Benchmark, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring (+5 more)

### Community 110 - "Species"
Cohesion: 0.10
Nodes (22): Mesh, Age, mature, sapling, young, Part, Plant, .height (+14 more)

### Community 111 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 112 - "Chunk"
Cohesion: 0.17
Nodes (15): GPUMaterial, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+7 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.11
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

### Community 119 - ".meshes"
Cohesion: 0.10
Nodes (10): GLTFModel, .bounds, .triangleCount, Light, float4x4, URL, .data, URL (+2 more)

### Community 120 - "HairTests"
Cohesion: 0.12
Nodes (13): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64 (+5 more)

### Community 121 - "Foliage"
Cohesion: 0.13
Nodes (15): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "PhysicsWorld"
Cohesion: 0.06
Nodes (34): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsParticle, .flags, Cloth, PhysicsJoint (+26 more)

### Community 125 - "VGStreamer"
Cohesion: 0.13
Nodes (13): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, Set, SIMD2, UInt32 (+5 more)

### Community 126 - "CityPlan"
Cohesion: 0.15
Nodes (12): CityPlan, Edge, open, party, street, Street, View, facade (+4 more)

### Community 127 - ".addFleshCharacter"
Cohesion: 0.19
Nodes (7): Float, float4x4, SDFShape, RagdollShapes, Float, float4x4, Range

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
Cohesion: 0.08
Nodes (51): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+43 more)

### Community 132 - "TraversalStats"
Cohesion: 0.39
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "XCTestCase"
Cohesion: 0.27
Nodes (3): StressSceneTests, VGStreamerTests, XCTestCase

### Community 135 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+15 more)

### Community 136 - "Config"
Cohesion: 0.11
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 137 - ".encodeSceneUpdate"
Cohesion: 0.11
Nodes (14): MTL4InstanceAccelerationStructureDescriptor, PrimitiveRefit, PrimitiveWork, PrimitiveWork4, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureUsage (+6 more)

### Community 138 - "SIMD4"
Cohesion: 0.10
Nodes (18): GPUPhysicsShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box, capsule (+10 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.09
Nodes (23): Tests, Float, float3x3, float4x4, UInt32, Wind, .megabytes, Entry (+15 more)

### Community 140 - "VirtualMesh"
Cohesion: 0.20
Nodes (14): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+6 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "Shaders.metal"
Cohesion: 0.08
Nodes (32): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+24 more)

### Community 144 - "Bool"
Cohesion: 0.12
Nodes (5): RenderThread, Thread, Void, Bool, .envText

### Community 145 - ".draw"
Cohesion: 0.06
Nodes (30): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants, Launch time (+22 more)

### Community 146 - "LayerSurface"
Cohesion: 0.12
Nodes (17): CGSize, NSFont, NSTextField, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize (+9 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Particles.metal"
Cohesion: 0.25
Nodes (16): uint, particleBeginKernel(), particleChildSeed(), particleColor(), particleEmitKernel(), particleFloor(), ParticleLayerParams, detail (+8 more)

### Community 149 - "LumenCards"
Cohesion: 0.19
Nodes (10): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+2 more)

### Community 150 - "QuartzCore"
Cohesion: 0.20
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (24): OptionSet, Parts, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+16 more)

### Community 152 - "ComputePass"
Cohesion: 0.09
Nodes (26): Where things are, ComputePass, MTLComputePipelineState, Step, FluidGPU, .summary, Steps, MTLBuffer (+18 more)

### Community 153 - ".trees"
Cohesion: 0.15
Nodes (7): Flora, Placement, SplitMix64, UInt32, UInt64, Void, UInt16

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - ".vgdebug"
Cohesion: 0.19
Nodes (7): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 159 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 160 - "TraceScene"
Cohesion: 0.06
Nodes (34): instance_acceleration_structure, RTPart, primitive_acceleration_structure, texture2d_array, uint2, TraceScene, clusterInstance, clusters (+26 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.18
Nodes (21): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit() (+13 more)

### Community 162 - "AppKit"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "float3"
Cohesion: 0.31
Nodes (9): float3, float3x3, float4x4, int3, particleCurl(), particleGradient(), particleMeshTransform(), particleNoise() (+1 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "dot"
Cohesion: 0.10
Nodes (10): Float16, simd_double3x3, .worldToView, dot, SDFVolume, .hi, Float, SDFTests (+2 more)

### Community 174 - "GPUMesh"
Cohesion: 0.18
Nodes (6): GPUMesh, UInt64, MTLDevice, RasterSceneTests, Float, MeshGeometry

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".clusterize"
Cohesion: 0.47
Nodes (5): LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.08
Nodes (24): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+16 more)

### Community 181 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 182 - "SceneBuffersTests"
Cohesion: 0.20
Nodes (6): SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 183 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "FoliageVoxels"
Cohesion: 0.18
Nodes (9): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, FoliageRuntimeTests (+1 more)

### Community 186 - ".length"
Cohesion: 0.12
Nodes (9): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, Float, SIMD8, Void, Float, .bodies (+1 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 189 - "PipelineCache"
Cohesion: 0.22
Nodes (5): PipelineCache, .count, PipelineCacheTests, UInt32, Value

### Community 190 - "ParticleCounts"
Cohesion: 0.15
Nodes (13): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+5 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

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

### Community 198 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 199 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 200 - ".init"
Cohesion: 0.25
Nodes (6): .isCancelled, LoadStep, .isCancelled, MTLCommandQueue, MTLDevice, URL

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "WorldTile"
Cohesion: 0.15
Nodes (9): .time, UInt64, URL, WorldTile, Data, StaticString, T, UInt (+1 more)

### Community 203 - "String"
Cohesion: 0.05
Nodes (37): MTLBlitCommandEncoder, MTLRenderPassDescriptor, NSColor, NSStackView, Section, NSCoder, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer (+29 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "Buffer"
Cohesion: 0.14
Nodes (11): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLCommandBuffer, MTLHeap (+3 more)

### Community 207 - "Terrain"
Cohesion: 0.28
Nodes (6): Float, SIMD2, UInt32, UInt64, Terrain, .cell

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

### Community 213 - "float4"
Cohesion: 0.09
Nodes (23): float4, uint4, Particle, info, position, velocity, ParticleEvent, a (+15 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "ParticleStep"
Cohesion: 0.11
Nodes (23): device, thread, particleBasis(), particleCollide(), ParticleCollider, a, b, particleCollideScene() (+15 more)

### Community 220 - "Particles: handoff (branch claude/init-branch-94ae07)"
Cohesion: 0.50
Nodes (3): Particles: handoff (branch claude/init-branch-94ae07), To do on the M4 Max, Traps found

### Community 221 - "RasterScene"
Cohesion: 0.28
Nodes (5): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLTexture

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "Camera"
Cohesion: 0.29
Nodes (4): Camera, .forward, .right, .up

### Community 224 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 225 - "SkinShell"
Cohesion: 0.33
Nodes (7): .cells, SkinOptions, SkinShell, Float, MeshGeometry, SIMD2, UInt32

### Community 226 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 227 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 228 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 229 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".updatePrimitives"
Cohesion: 0.29
Nodes (4): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder

### Community 233 - ".checkPool"
Cohesion: 0.38
Nodes (5): Hashable, Key, StaticString, UInt, UInt32

### Community 234 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 235 - "Shape"
Cohesion: 0.25
Nodes (8): Shape, box, .code, disc, point, .radius, ring, sphere

### Community 236 - "Heavens"
Cohesion: 0.25
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 239 - "boxCandidate"
Cohesion: 0.48
Nodes (7): boxCandidate(), clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 240 - "constant"
Cohesion: 0.22
Nodes (19): Built, constant, float2, kernel, read, read_write, SCENE_ACCEL, texture2d (+11 more)

### Community 241 - "ParticlesCPU"
Cohesion: 0.33
Nodes (6): GPUParticleEmitter, ParticleEvent, .seed, .spawn, ParticlesCPU, .current

### Community 242 - "VGBlas"
Cohesion: 0.29
Nodes (7): VGBlas, attrs, pad0, pad1, pad2, triangles, tris

### Community 243 - ".testTheCutsBLASHoldsTheCutsTriangles"
Cohesion: 0.33
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are

### Community 246 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 248 - ".load"
Cohesion: 0.40
Nodes (4): MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture

### Community 249 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 251 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

## Knowledge Gaps
- **1655 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1650 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2223 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **19 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.simplify`, `SettingsTable`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `ParticleSystem`, `LightTable`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `ParticlesGPU`, `RadianceCascades`, `SectionFile`, `.write`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `.part`, `RendererController`, `SceneKind`, `SIMD3`, `MuscleAtlas`, `AABB`, `VirtualTracing`, `Rect`, `FluidSystem`, `Metal3Pass`, `RasterClusters`, `LoadingOverlay`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `GPULight`, `Double`, `Float`, `FoliageTextures`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `FluidTests`, `PhysicsTests`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `ParticleTests`, `Benchmark`, `Species`, `.write`, `Chunk`, `BuildingAssembler`, `.meshes`, `HairTests`, `Foliage`, `PhysicsWorld`, `VGStreamer`, `CityPlan`, `.addFleshCharacter`, `SettingsTableTests`, `Slot`, `TraversalStats`, `XCTestCase`, `Config`, `.encodeSceneUpdate`, `SIMD4`, `VoxelLOD`, `Bool`, `LayerSurface`, `LumenCards`, `.buildStress`, `ComputePass`, `.trees`, `Phyllotaxis`, `FBXError`, `FBXFile`, `dot`, `GPUMesh`, `.clusterize`, `LumenGlobalSDF`, `SceneBuffersTests`, `FoliageVoxels`, `.length`, `PipelineCache`, `.addHair`, `.init`, `RagdollTests`, `WorldTile`, `String`, `Buffer`, `Terrain`, `RasterScene`, `LightKind`, `SkinShell`, `.encoder`, `.commit`, `.updatePrimitives`, `.checkPool`, `RenderPass4`, `WorldPlace`, `SplitMix64`, `ParticlesCPU`?**
  _High betweenness centrality (0.345) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `FramePlan`, `flagOn`, `Kernel`?**
  _High betweenness centrality (0.116) - this node is a cross-community bridge._
- **Why does `Map` connect `SceneBuffers` to `GLTFLoader`, `VoxelLOD`, `VirtualMesh`, `FluidSurface.metal`, `.buildStress`, `Int`, `SkinnedCharacter`, `Renderer`, `ParticlesGPU`, `TraceScene`, `SectionFile`, `MuscleAtlas`, `PipelineCache`, `VirtualTracing`, `RasterClusters`, `LoadingOverlay`, `Terrain`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `Capabilities`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `KernelVariantsTests`, `.write`, `ParticlesCPU`, `Particles`, `.load`, `VGStreamer`, `CityPlan`?**
  _High betweenness centrality (0.107) - this node is a cross-community bridge._
- **Are the 48 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 48 INFERRED edges - model-reasoned connections that need verification._
- **Are the 25 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 25 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `PhysicsWorld` (e.g. with `GPUPhysicsGrab` and `.encodeHairCurves()`) actually correct?**
  _`PhysicsWorld` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1655 weakly-connected nodes found - possible documentation gaps or missing edges._