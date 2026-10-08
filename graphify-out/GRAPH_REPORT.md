# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 230 files · ~1,256,261 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6883 nodes · 21082 edges · 246 communities (226 shown, 20 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3236 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `3f3eee0f`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- FluidSystem
- .simplify
- Fluid.metal
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- FramePlan
- FrameEncoder
- Metal4Frame
- translate
- ParticleSystem
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
- ParticlesGPU
- traceKernel
- restirSpatialKernel
- restirGIInitialKernel
- RadianceCascades
- SIMD4
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- .write
- String
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- FBXFile
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- ParticleMath
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Shaders.metal
- SDFBox
- MeshData
- Direct Rendering Stress Test 32
- SIMD3
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- Rect
- PhysicsWorld
- simd
- RenderPass
- VoxelGrids
- RendererController
- AABB
- KernelVariants
- ab.sh
- LoadActivity
- instanceRecord
- uint
- .meshes
- .load
- Double
- Capabilities
- Foliage
- FoliageTextures
- SurfaceKind
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
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
- ParticleTests
- CameraTrack
- Images
- Species
- .write
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- GLTFModel
- SDFBuffers
- Int
- same.sh
- Float
- baseline.sh
- PlantTracing
- CityPlan
- SDFShape
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- XCTestCase
- ParticleEmitter
- Config
- Shape
- .sampled
- VoxelLOD
- LumenMeshSDF
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- .draw
- Measuring MetalRenderer
- LayerSurface
- VSMCounters
- particleLightKernel
- Hit
- QuartzCore
- .buildStress
- Pipelines
- Detail
- Crown
- .vgdebug
- Phyllotaxis
- Stage
- FBXError
- FBXReader.swift
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- .used
- RTVoxels
- Post.metal
- VGParams
- Particles.metal
- .useHeap
- .plant
- VSM.metal
- .part
- RasterScene
- device
- VSMView
- Lumen.swift
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- SceneShading
- SceneBuffersTests
- SkyParams
- VSMParams
- FoliageRuntimeTests
- .xyz
- RasterParams
- Benchmark
- Key
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
- .sources
- RagdollTests
- WorldTests
- .compute
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
- .generate
- ParticleStep
- Particles: handoff (branch claude/init-branch-94ae07)
- .int
- PhysicsSkinAttach
- WindFrame
- PlantTracingTests
- FleshFigure
- .encoder
- .capture
- Types.metal
- KernelVariantsTests
- HairBSDF
- .commit
- CharacterLibrary
- .setBytes
- RenderPass4
- Shape
- Float
- WorldPlace
- VoxelBox
- clusterWalk
- particleLayerKernel
- Map
- .dispatchThreads
- .setComputePipelineState
- .mark
- .useResource

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 431 edges
2. `Scene` - 303 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 263 edges
5. `Kernel` - 161 edges
6. `.length` - 155 edges
7. `SIMD4` - 154 edges
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

## Communities (246 total, 20 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (62): GPUEmissiveTriangle, GPUMesh, UInt64, meshLights, Assembly, Bone, BorrowedLight, BorrowedMesh (+54 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.09
Nodes (43): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+35 more)

### Community 3 - "RenderSettings"
Cohesion: 0.11
Nodes (41): Bound, Codable, Equatable, ParticleEmitter, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings (+33 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (77): clipSegment(), ggxFromDirection(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular(), LightSubset (+69 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.11
Nodes (38): half4, float2, float3, float4, primitive_acceleration_structure, SCENE_ACCEL, texture2d_array, thread (+30 more)

### Community 6 - "FluidSystem"
Cohesion: 0.19
Nodes (13): .surfaceCapacity, Float, UInt32, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims (+5 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "Bool"
Cohesion: 0.07
Nodes (29): F, UnsafeMutableBufferPointer, Bool, .envText, Control, checkbox, custom, popup (+21 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView (+10 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.14
Nodes (28): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+20 more)

### Community 13 - "FramePlan"
Cohesion: 0.17
Nodes (13): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, DenoiseSignal, FramePlan, .prev, FrameSize (+5 more)

### Community 14 - "FrameEncoder"
Cohesion: 0.05
Nodes (37): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor (+29 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.13
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.13
Nodes (23): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, Camera, .forward, .right, .up, rotate(), scale() (+15 more)

### Community 17 - "ParticleSystem"
Cohesion: 0.10
Nodes (23): GPUParticleEmitter, Flags, Orientation, axis, .code, rayFacing, velocity, world (+15 more)

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.14
Nodes (29): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+21 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (75): distance, makeRay(), constant, device, float2, float3, float4, kernel (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.08
Nodes (25): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLBuffer, MTLCommandBuffer (+17 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (60): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+52 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (16): GPUJoint, .parent, Clip, .duration, .loopKeys, Level, .triangleCount, SkinnedCharacter (+8 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (142): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+134 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.11
Nodes (17): NSControl, NSGridView, Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel (+9 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (85): 8. Pipelines and resources, Error, MetalKit, LoadError, unreadable, SkyImage, Set, GPUFogParams (+77 more)

### Community 31 - "ParticlesGPU"
Cohesion: 0.11
Nodes (16): Part, Build, Counter, Part, ParticlesGPU, Float, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+8 more)

### Community 32 - "traceKernel"
Cohesion: 0.06
Nodes (75): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+67 more)

### Community 33 - "restirSpatialKernel"
Cohesion: 0.09
Nodes (41): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, emptyReservoir(), constant (+33 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (44): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+36 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "SIMD4"
Cohesion: 0.06
Nodes (40): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUJointMatrix, GPUMegaLightsParams, GPUMuscle, GPUParticleStep (+32 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.09
Nodes (19): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array (+11 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.15
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "String"
Cohesion: 0.03
Nodes (86): CaseIterable, NSColor, Section, NSCoder, Options, MTLAccelerationStructureUsage, Body, muscles (+78 more)

### Community 43 - "VSMTargets"
Cohesion: 0.08
Nodes (30): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+22 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (39): Lumen, MTLBuffer, MTLDevice, MTLTexture, SIMD2, .empty, RTPart, MTLCommandQueue (+31 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.12
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.09
Nodes (13): NSApplication, NSApplicationDelegate, NSMenuItem, NSObject, AppDelegate, Any, Notification, NSWindow (+5 more)

### Community 49 - "Crowd"
Cohesion: 0.12
Nodes (20): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+12 more)

### Community 50 - "FBXFile"
Cohesion: 0.20
Nodes (9): IteratorProtocol, Sequence, Children, Connection, FBXFile, .topLevel, Node, StaticString (+1 more)

### Community 51 - "DebugPanel"
Cohesion: 0.08
Nodes (18): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification (+10 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "ParticleMath"
Cohesion: 0.17
Nodes (8): GPUParticleCollider, GPUParticleRender, Fragment, ParticleMath, Rng, Float, SIMD2, UInt32

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
Nodes (39): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+31 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (109): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+101 more)

### Community 62 - "SDFBox"
Cohesion: 0.10
Nodes (21): device, SDFBox, pad0, pad1, pad2, pad3, scene, shape (+13 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "SIMD3"
Cohesion: 0.05
Nodes (35): Float16, Int8, simd_float4x4, Atmosphere, Float, GPUInstanceData, LocalIds, MeshClusterizer (+27 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.08
Nodes (21): .instanceAS, .virtualGeometryChanged, MTLResource, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, MTLTexture (+13 more)

### Community 73 - "Rect"
Cohesion: 0.09
Nodes (25): .area, Float, Block, Lamp, Lot, .front, .size, .transform (+17 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.09
Nodes (21): Int32, GPUFluidParams, GPUFluidParticle, PhysicsWorld, .buckets, .cellSize, .kinematicRows, .params (+13 more)

### Community 76 - "RenderPass"
Cohesion: 0.08
Nodes (10): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, MTLResource, MTLResourceUsage (+2 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.15
Nodes (18): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, MTLResource (+10 more)

### Community 78 - "RendererController"
Cohesion: 0.10
Nodes (15): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles, RendererController (+7 more)

### Community 79 - "AABB"
Cohesion: 0.08
Nodes (24): AABB, .area, .centroid, .isEmpty, BinScratch, BVHBuilder, BVHNode, Node (+16 more)

### Community 80 - "KernelVariants"
Cohesion: 0.23
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, .pending (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.06
Nodes (31): NSFont, NSPoint, NSStackView, NSView, Sendable, Job, .heading, LoadActivity (+23 more)

### Community 83 - "instanceRecord"
Cohesion: 0.14
Nodes (35): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+27 more)

### Community 84 - "uint"
Cohesion: 0.22
Nodes (18): boxCandidate(), candidate(), candidatePart(), card(), countedHit(), intersectAny(), intersectClosest(), intersectClosestCost() (+10 more)

### Community 85 - ".meshes"
Cohesion: 0.06
Nodes (38): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+30 more)

### Community 86 - ".load"
Cohesion: 0.18
Nodes (7): CustomStringConvertible, Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 87 - "Double"
Cohesion: 0.17
Nodes (14): Double, World, .anchorTile, .start, Block, City, Ground, Highway (+6 more)

### Community 88 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.17
Nodes (17): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+9 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "ParticleTextures"
Cohesion: 0.13
Nodes (17): Kind, bubble, flame, ring, rune, smoke, spark, streak (+9 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (54): groupElement(), uint4, cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi (+46 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (21): Metal3Pass, .declarationScope, AnyObject, FluidWorld, LiquidKind, blood, honey, .look (+13 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.08
Nodes (14): Cloth, Set, .length, HairTests, Float, MTLCommandQueue, MTLDevice, Void (+6 more)

### Community 98 - "MuscleTests"
Cohesion: 0.16
Nodes (5): MuscleTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 99 - "Footprint"
Cohesion: 0.14
Nodes (15): BuildingGenerator, BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops, roof (+7 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (22): ArraySlice, GPUPhysicsParticle, GPUSoftEmbed, GPUSoftVertex, .particleCellSize, NearCache, SoftModel, .near (+14 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.21
Nodes (8): Building, .triangleCount, Module, Data, float4x4, BuildingTests, Float, SIMD2

### Community 105 - "SurfaceMaterial"
Cohesion: 0.10
Nodes (21): SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle, PlanShape (+13 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "ParticleTests"
Cohesion: 0.18
Nodes (11): Hashable, GPUParticle, Key, ParticleTests, Float, MTLCommandQueue, MTLDevice, StaticString (+3 more)

### Community 108 - "CameraTrack"
Cohesion: 0.13
Nodes (7): CameraTrack, .duration, Key, Float, ShowcaseLook, Float, Void

### Community 109 - "Images"
Cohesion: 0.18
Nodes (3): 6. Math, Modes, Images

### Community 110 - "Species"
Cohesion: 0.12
Nodes (12): Species, birch, bush, conifer, dead, fern, grass, .hasBoughs (+4 more)

### Community 111 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 112 - "WorldTile"
Cohesion: 0.12
Nodes (19): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+11 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.09
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.32
Nodes (9): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+1 more)

### Community 118 - "lumenTraceKernel"
Cohesion: 0.21
Nodes (28): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel(), LumenScreenHit (+20 more)

### Community 119 - "GLTFModel"
Cohesion: 0.24
Nodes (9): GLTFModel, .bounds, .triangleCount, Light, Material, Mesh, float4x4, SIMD2 (+1 more)

### Community 120 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 121 - "Int"
Cohesion: 0.03
Nodes (58): Result, Float, UnsafeBufferPointer, Params, RasterClusters, .drawnByCamera, .stats, .summary (+50 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Float"
Cohesion: 0.18
Nodes (7): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape

### Community 125 - "PlantTracing"
Cohesion: 0.12
Nodes (20): Tests, float3x3, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, Float (+12 more)

### Community 126 - "CityPlan"
Cohesion: 0.15
Nodes (12): CityPlan, Edge, open, party, street, Street, View, facade (+4 more)

### Community 127 - "SDFShape"
Cohesion: 0.09
Nodes (27): RagdollShapes, Float, float4x4, Range, Node, .transform, Op, intersect (+19 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (43): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+35 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (8): Settings: `SettingsTable.swift`, SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.14
Nodes (13): Slot, accent, blind, dark, floor, frame, glass, interior (+5 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (49): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+41 more)

### Community 132 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "XCTestCase"
Cohesion: 0.19
Nodes (5): GLTFLoaderTests, PipelineCacheTests, UInt32, StressSceneTests, XCTestCase

### Community 135 - "ParticleEmitter"
Cohesion: 0.10
Nodes (20): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+12 more)

### Community 137 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 138 - ".sampled"
Cohesion: 0.14
Nodes (11): simd_double3x3, GPUPhysicsShape, PhysicsShapeKind, box, capsule, plane, sdf, sphere (+3 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.16
Nodes (27): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+19 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (19): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device (+11 more)

### Community 144 - ".draw"
Cohesion: 0.14
Nodes (15): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Things that are not structures yet, Where new code belongs (+7 more)

### Community 145 - "Measuring MetalRenderer"
Cohesion: 0.12
Nodes (11): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table, Proving a refactor changed nothing, Scorers and other tools (+3 more)

### Community 146 - "LayerSurface"
Cohesion: 0.15
Nodes (14): CGSize, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title (+6 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "particleLightKernel"
Cohesion: 0.30
Nodes (16): constant, device, kernel, SCENE_ACCEL, uint, particleBeginKernel(), particleChildSeed(), particleEmitKernel() (+8 more)

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.17
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (25): OptionSet, Parts, Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+17 more)

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (30): ComputePass, MTLBarrierScope, MTLComputePipelineState, MTLComputePipelineState, Step, FluidGPU, .summary, Steps (+22 more)

### Community 153 - "Detail"
Cohesion: 0.67
Nodes (3): Detail, flat, full

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - ".vgdebug"
Cohesion: 0.14
Nodes (11): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are, Offscreen rendering in MetalRenderer, Recipes (+3 more)

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "FBXError"
Cohesion: 0.24
Nodes (9): FBXError, .description, BlobReader, Mapping, controlPoint, polygonVertex, Data, StaticString (+1 more)

### Community 159 - "FBXReader.swift"
Cohesion: 0.19
Nodes (9): Compression, Contents, FBXArrayElement, unsupported, Float, Int64, MappedFile, UnsafeRawPointer (+1 more)

### Community 160 - "TraceScene"
Cohesion: 0.07
Nodes (30): instance_acceleration_structure, RTPart, primitive_acceleration_structure, texture2d_array, uint2, TraceScene, clusterInstance, clusters (+22 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.17
Nodes (26): geometry_type, intersection_params, anyHit(), assumeCurves(), assumeCurveShape(), candidateIndex(), closestDistance(), closestHit() (+18 more)

### Community 162 - "AppKit"
Cohesion: 0.13
Nodes (6): AppKit, CoreGraphics, ImageIO, SplitMix64, UInt64, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "Particles.metal"
Cohesion: 0.26
Nodes (13): float3, int3, thread, particleBasis(), particleCollide(), ParticleCollider, a, b (+5 more)

### Community 171 - ".plant"
Cohesion: 0.23
Nodes (11): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+3 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - ".part"
Cohesion: 0.35
Nodes (8): simd_double4x4, simd_quatd, CharacterImporter, Part, Skeleton, .bindPositions, .bindRotations, SourceClip

### Community 174 - "RasterScene"
Cohesion: 0.10
Nodes (17): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+9 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "Lumen.swift"
Cohesion: 0.33
Nodes (6): LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLComputePipelineState, UInt32

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.08
Nodes (23): Uniforms, Void, Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer (+15 more)

### Community 181 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 182 - "SceneBuffersTests"
Cohesion: 0.22
Nodes (6): SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 183 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - ".xyz"
Cohesion: 0.07
Nodes (23): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsCandidate (+15 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 189 - "Key"
Cohesion: 0.26
Nodes (5): Key, PipelineCache, .count, MTLComputePipelineState, Value

### Community 190 - "ParticleCounts"
Cohesion: 0.17
Nodes (12): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+4 more)

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

### Community 200 - ".sources"
Cohesion: 0.36
Nodes (3): LoadStep, MTLCommandQueue, MTLDevice

### Community 201 - "RagdollTests"
Cohesion: 0.16
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "WorldTests"
Cohesion: 0.17
Nodes (6): UInt32, Data, StaticString, T, UInt, WorldTests

### Community 203 - ".compute"
Cohesion: 0.20
Nodes (6): MTLBlitCommandEncoder, MTLRenderPassDescriptor, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder

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
Cohesion: 0.20
Nodes (10): float4, uint4, Particle, info, position, velocity, particleColor(), ParticleEvent (+2 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "ParticleStep"
Cohesion: 0.20
Nodes (10): ParticleStep, capacity, colliders, dt, emitters, gravity, parity, step (+2 more)

### Community 220 - "Particles: handoff (branch claude/init-branch-94ae07)"
Cohesion: 0.22
Nodes (7): Built (phase 1), Particles: handoff (branch claude/init-branch-94ae07), Phase 2 (next), To do on the M4 Max, Traps found, MTL4ComputeCommandEncoder, MTLAllocation

### Community 221 - ".int"
Cohesion: 0.53
Nodes (3): invalid, T, UnsafeRawBufferPointer

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 224 - "PlantTracingTests"
Cohesion: 0.31
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 225 - "FleshFigure"
Cohesion: 0.09
Nodes (22): .cells, Axis, along, front, up, Flesh, FleshOptions, MuscleSpec (+14 more)

### Community 226 - ".encoder"
Cohesion: 0.19
Nodes (6): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope

### Community 227 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 228 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 229 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "CharacterLibrary"
Cohesion: 0.29
Nodes (6): BlobWriter, CharacterLibrary, .directory, concurrently(), URL, Void

### Community 234 - "RenderPass4"
Cohesion: 0.16
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState

### Community 235 - "Shape"
Cohesion: 0.25
Nodes (8): Shape, box, .code, disc, point, .radius, ring, sphere

### Community 236 - "Float"
Cohesion: 0.14
Nodes (11): Flora, Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation, Placement (+3 more)

### Community 237 - "WorldPlace"
Cohesion: 0.29
Nodes (5): Float, Float, SIMD2, WorldPlace, .anchor

### Community 238 - "VoxelBox"
Cohesion: 0.29
Nodes (7): VoxelBox, cells, grid, level, pad0, pad1, pad2

### Community 239 - "clusterWalk"
Cohesion: 0.53
Nodes (6): clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 240 - "particleLayerKernel"
Cohesion: 0.33
Nodes (6): read, texture2d, texture3d, uint2, write, particleLayerKernel()

### Community 241 - "Map"
Cohesion: 0.15
Nodes (12): Map, ParticleEvent, .seed, .spawn, ParticlesCPU, .current, Particles, bubbles (+4 more)

## Knowledge Gaps
- **1611 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1606 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2183 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **20 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `FluidSystem`, `.simplify`, `Bool`, `FramePlan`, `FrameEncoder`, `Metal4Frame`, `translate`, `ParticleSystem`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `ParticlesGPU`, `RadianceCascades`, `SectionFile`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `ParticleMath`, `MuscleAtlas`, `SIMD3`, `VirtualTracing`, `Rect`, `PhysicsWorld`, `RenderPass`, `VoxelGrids`, `RendererController`, `AABB`, `KernelVariants`, `LoadActivity`, `.meshes`, `Double`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `Metal3Pass`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `ParticleTests`, `Images`, `Species`, `.write`, `WorldTile`, `BuildingAssembler`, `GLTFModel`, `SDFBuffers`, `Float`, `PlantTracing`, `CityPlan`, `SDFShape`, `SettingsTableTests`, `Slot`, `TraversalStats`, `XCTestCase`, `Config`, `.sampled`, `VoxelLOD`, `LayerSurface`, `.buildStress`, `Pipelines`, `Detail`, `Phyllotaxis`, `FBXError`, `FBXReader.swift`, `AppKit`, `.used`, `.plant`, `.part`, `RasterScene`, `LumenGlobalSDF`, `SceneBuffersTests`, `FoliageRuntimeTests`, `.xyz`, `Benchmark`, `Key`, `.addHair`, `.sources`, `RagdollTests`, `WorldTests`, `Buffer`, `Terrain`, `.int`, `WindFrame`, `PlantTracingTests`, `FleshFigure`, `.commit`, `CharacterLibrary`, `.setBytes`, `RenderPass4`, `Float`, `WorldPlace`, `Map`?**
  _High betweenness centrality (0.317) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `traceKernel`, `restirSpatialKernel`, `KernelVariantsTests`, `.draw`, `Pipelines`, `Kernel`?**
  _High betweenness centrality (0.129) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `VoxelLOD`, `FluidSurface.metal`, `.buildStress`, `Pipelines`, `TextureStreamer`, `SkinnedCharacter`, `Renderer`, `ParticlesGPU`, `TraceScene`, `SectionFile`, `SceneBuffers`, `MuscleAtlas`, `Key`, `VirtualTracing`, `VoxelGrids`, `Terrain`, `LoadActivity`, `.meshes`, `.load`, `Capabilities`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `KernelVariantsTests`, `.write`, `Int`, `PlantTracing`, `CityPlan`?**
  _High betweenness centrality (0.123) - this node is a cross-community bridge._
- **Are the 42 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 42 INFERRED edges - model-reasoned connections that need verification._
- **Are the 25 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 25 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `PhysicsWorld` (e.g. with `GPUPhysicsGrab` and `.encodeHairCurves()`) actually correct?**
  _`PhysicsWorld` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1611 weakly-connected nodes found - possible documentation gaps or missing edges._