# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 248 files · ~1,292,783 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 7386 nodes · 22692 edges · 251 communities (234 shown, 17 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3450 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `45e5dd42`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- AABB
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- traceKernel
- .simplify
- Fluid.metal
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- FramePlan
- ParticlesGPU
- Metal4Frame
- translate
- ParticleEmitter
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- PlantEditorModel
- Kernel
- SettingsPanel
- Renderer
- Build
- pcgHash
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
- FBXFile
- RendererController
- SceneKind
- 3D Geometric Test Scene
- ParticleMath
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
- RasterClusters
- SDFShape
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- uint
- VirtualBLAS
- View
- Double
- Capabilities
- Float
- FoliageTextures
- ProceduralTextures
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- FluidTests
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
- String
- Benchmark
- .library
- Map
- PlantCatalog
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- Scene
- HairTests
- Foliage
- same.sh
- Float
- baseline.sh
- PlantTracing
- ParticleSystem
- Camera
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- Int
- PlantWind
- Config
- ParticleEmitter
- WindFrame
- FrameEncoder
- SIMD3
- VoxelLOD
- VirtualMesh
- FluidSurface.metal
- RasterClusters.metal
- Tests
- Rect
- .draw
- RagdollTests
- VSMCounters
- Particles.metal
- LumenMeshSDF
- QuartzCore
- .buildStress
- Pipelines
- PlantEditorTests
- Curve
- Where things are
- Images
- CameraTrack
- compositeKernel
- Post.metal
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- CurveEditor
- RTVoxels
- .vgdebug
- VGParams
- float3
- liquidKernel
- FoliageRuntimeTests
- VSM.metal
- dot
- SceneSettings
- RendererError
- VSMView
- VGStreamer
- VSMClusterArgs
- VSMScene
- .init
- SceneShading
- .icosphere
- SkyParams
- VSMParams
- VoxelGrids
- PhysicsWorld
- RasterParams
- .stages
- Key
- ParticleCounts
- VSMInstance
- LumenSDFHit
- device
- PhysicsJoint
- RasterCounters
- ParticleTrailPose
- ParticleLayerParams
- SettingsStore
- Key
- RasterInstance
- PlantGoldenTests
- WorldTile
- .end
- PhysicsGrab
- PhysPush
- .requestLevels
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
- Clip
- RasterScene
- PhysicsSkinAttach
- SurfaceKind
- LightKind
- .addFleshCharacter
- PostParams
- .capture
- TextureStreamWork
- KernelVariantsTests
- HairBSDF
- BuildingTier
- float4
- .clusterize
- PlantSpecies.swift
- .addHair
- uint
- .used
- LumenRadiosityParams
- boxCandidate
- particleOverlayKernel
- Types.metal
- VGBlas
- InstanceData
- LumenParams
- Shape
- CacheTests
- ParticleDistortParams
- VGRasterInstance
- Detail
- .snapshot

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 447 edges
2. `Scene` - 314 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 267 edges
5. `Kernel` - 167 edges
6. `.length` - 162 edges
7. `SIMD4` - 161 edges
8. `Foliage` - 151 edges
9. `simd` - 127 edges
10. `Benchmark` - 113 edges

## Surprising Connections (you probably didn't know these)
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift

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

## Communities (251 total, 17 thin omitted)

### Community 0 - "AABB"
Cohesion: 0.06
Nodes (27): AABB, .area, .centroid, .isEmpty, float4x4, GLTFModel, .bounds, .triangleCount (+19 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (48): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+40 more)

### Community 3 - "RenderSettings"
Cohesion: 0.08
Nodes (57): Bound, Codable, Equatable, ParticleEmitter, Cover, UInt32, UInt64, AgeRule (+49 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (72): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+64 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.08
Nodes (58): half4, float2, float3, float4, primitive_acceleration_structure, read, SCENE_ACCEL, texture2d (+50 more)

### Community 6 - "traceKernel"
Cohesion: 0.10
Nodes (50): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+42 more)

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
Nodes (28): F, .isDirty, Bool, .envText, Control, checkbox, custom, popup (+20 more)

### Community 11 - "RenderView"
Cohesion: 0.05
Nodes (31): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, FrameOutput, LayerSurface (+23 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.17
Nodes (17): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, MetalKit, ComputeStage, CompositeInputs, DenoiseSignal, DenoiseTargets, FramePlan (+9 more)

### Community 14 - "ParticlesGPU"
Cohesion: 0.12
Nodes (15): Part, Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, Counter (+7 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.04
Nodes (48): CAMetalLayer, Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue (+40 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (16): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+8 more)

### Community 17 - "ParticleEmitter"
Cohesion: 0.07
Nodes (27): Orientation, axis, .code, rayFacing, velocity, world, ParticleCollider, box (+19 more)

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
Nodes (75): makeRay(), constant, device, float2, float3, float4, kernel, Light (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.14
Nodes (14): Entry, Level, Data, MTLBuffer, MTLHeap, UInt32, URL, TextureStreamer (+6 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (58): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), giLightIllum(), lastFramePixel(), LightCandidate, element, uv (+50 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (19): simd_double4x4, GPUJoint, .parent, GPUJointMatrix, Clip, .duration, .loopKeys, Level (+11 more)

### Community 27 - "PlantEditorModel"
Cohesion: 0.08
Nodes (21): Reading the table, Combine, Element, ObservableObject, Array, PlantEditorHost, PlantEditorModel, .def (+13 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (148): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+140 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (72): To do on the M4 Max, 8. Pipelines and resources, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, GPUSkyParams, done (+64 more)

### Community 31 - "Build"
Cohesion: 0.12
Nodes (15): Build, Part, .trailShape, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLAllocation, MTLBuffer (+7 more)

### Community 32 - "pcgHash"
Cohesion: 0.06
Nodes (56): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+48 more)

### Community 33 - "restirSpatialKernel"
Cohesion: 0.13
Nodes (31): lightSampleTarget(), emptyReservoir(), constant, device, float2, float4, kernel, read (+23 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.06
Nodes (52): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUMegaLightsParams, GPUMuscle (+44 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (17): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array (+9 more)

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
Cohesion: 0.03
Nodes (80): CaseIterable, CityStyle, mixed, modern, office, oldtown, residential, .title (+72 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (32): .empty, LoadOptions, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, MTLAccelerationStructure, InstanceBlock (+24 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.14
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.07
Nodes (21): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindowDelegate, AppDelegate, Any, Notification, NSWindow (+13 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (17): Crowd, .liveStates, Motion, .isBlend, Part, Slot, State, Float (+9 more)

### Community 50 - "FBXFile"
Cohesion: 0.06
Nodes (43): Compression, IteratorProtocol, Sequence, simd_quatd, Children, Connection, Contents, FBXArrayElement (+35 more)

### Community 51 - "RendererController"
Cohesion: 0.05
Nodes (33): DebugInfo, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Float (+25 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (41): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+33 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "ParticleMath"
Cohesion: 0.16
Nodes (9): GPUParticleCollider, GPUParticleField, GPUParticleRender, Fragment, ParticleMath, Rng, Float, SIMD2 (+1 more)

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
Nodes (88): Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+80 more)

### Community 62 - "SDFBox"
Cohesion: 0.10
Nodes (21): device, SDFBox, pad0, pad1, pad2, pad3, scene, shape (+13 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.10
Nodes (19): Int8, Baked, bricks, heights, Heightfield, .hi, MeshSDF, .bytes (+11 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (18): .virtualGeometryChanged, MTLResource, Content, MTLAccelerationStructure, MTLBuffer, MTLTexture, UInt32, TraceSceneArgs (+10 more)

### Community 73 - "CityPlan"
Cohesion: 0.10
Nodes (24): Block, CityPlan, Edge, open, party, street, Lamp, Lot (+16 more)

### Community 74 - "Int32"
Cohesion: 0.10
Nodes (20): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem (+12 more)

### Community 76 - "RenderPass"
Cohesion: 0.08
Nodes (10): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, MTLResource, MTLResourceUsage (+2 more)

### Community 77 - "RasterClusters"
Cohesion: 0.09
Nodes (24): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+16 more)

### Community 78 - "SDFShape"
Cohesion: 0.06
Nodes (40): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+32 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.18
Nodes (16): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, .pending (+8 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.06
Nodes (30): NSFont, NSPoint, NSView, Sendable, Job, .heading, LoadActivity, .onChange (+22 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.20
Nodes (27): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+19 more)

### Community 84 - "uint"
Cohesion: 0.12
Nodes (34): candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart() (+26 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.15
Nodes (20): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+12 more)

### Community 86 - "View"
Cohesion: 0.09
Nodes (37): E, .body, EditorGroup, ParamRow, .body, ParamRows, .body, Root (+29 more)

### Community 87 - "Double"
Cohesion: 0.09
Nodes (27): Float, Double, World, .anchorTile, .start, Block, City, Flora (+19 more)

### Community 88 - "Capabilities"
Cohesion: 0.13
Nodes (13): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Capabilities: `Capabilities.swift`, Launch, Capabilities (+5 more)

### Community 89 - "Float"
Cohesion: 0.13
Nodes (18): Level, Float, Card, Carve, Graft, Grower, LeafRecipe, Level (+10 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.18
Nodes (10): Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32, UInt8 (+2 more)

### Community 92 - "ParticleTextures"
Cohesion: 0.11
Nodes (22): Kind, Aux, flameMotion, .layer, smokeBack, smokeLight, Kind, bubble (+14 more)

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
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.11
Nodes (9): Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape (+1 more)

### Community 98 - "MuscleTests"
Cohesion: 0.15
Nodes (4): MuscleTests, Float, MTLCommandQueue, MTLDevice

### Community 99 - "Footprint"
Cohesion: 0.25
Nodes (8): BuildingSpec, Footprint, .cover, .loops, Float, SIMD2, UInt64, on

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
Cohesion: 0.19
Nodes (9): Building, .triangleCount, BuildingGenerator, Module, Data, float4x4, BuildingTests, Float (+1 more)

### Community 105 - "SurfaceMaterial"
Cohesion: 0.13
Nodes (16): SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle, PlanShape (+8 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "ParticleTests"
Cohesion: 0.17
Nodes (9): Hashable, GPUParticle, Key, ParticleTests, Float, StaticString, UInt, UInt32 (+1 more)

### Community 108 - "String"
Cohesion: 0.04
Nodes (44): L, MTLBlitCommandEncoder, MTLRenderPassDescriptor, NSColor, NSStackView, Section, NSCoder, Frame (+36 more)

### Community 109 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 110 - ".library"
Cohesion: 0.08
Nodes (25): Mesh, RawRepresentable, Age, mature, sapling, young, Bone, Part (+17 more)

### Community 111 - "Map"
Cohesion: 0.12
Nodes (16): Map, BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile (+8 more)

### Community 112 - "PlantCatalog"
Cohesion: 0.10
Nodes (17): .savedDef, PlantCatalog, .count, .covers, File, Foliage.SpeciesDef, .fingerprint, .launch (+9 more)

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
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 119 - "Scene"
Cohesion: 0.04
Nodes (45): .parts, GPUEmissiveTriangle, meshLights, BorrowedLight, CityLight, CurveMesh, Float, Instance (+37 more)

### Community 120 - "HairTests"
Cohesion: 0.13
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 121 - "Foliage"
Cohesion: 0.15
Nodes (15): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Float"
Cohesion: 0.18
Nodes (8): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, UInt32

### Community 125 - "PlantTracing"
Cohesion: 0.10
Nodes (23): 7. Acceleration structures and ray tracing, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, Float (+15 more)

### Community 126 - "ParticleSystem"
Cohesion: 0.10
Nodes (19): GPUParticleEmitter, Flags, .gpu, ParticleSystem, .billboardCapacity, .distortRange, .gpuColliders, .gpuEmitters (+11 more)

### Community 127 - "Camera"
Cohesion: 0.13
Nodes (13): Darwin, Camera, .forward, .right, .up, rotate(), Float, float4x4 (+5 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (8): Settings: `SettingsTable.swift`, SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.12
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "Int"
Cohesion: 0.08
Nodes (24): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+16 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 135 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+15 more)

### Community 136 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 137 - "FrameEncoder"
Cohesion: 0.05
Nodes (35): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp (+27 more)

### Community 138 - "SIMD3"
Cohesion: 0.08
Nodes (23): GPUPhysicsShape, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+15 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - "VirtualMesh"
Cohesion: 0.12
Nodes (17): .data, Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32 (+9 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "Tests"
Cohesion: 0.33
Nodes (6): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Tests, Timings, What could not be run

### Community 144 - "Rect"
Cohesion: 0.24
Nodes (6): .area, Ends, Float, Rect, .center, .size

### Community 145 - ".draw"
Cohesion: 0.11
Nodes (15): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Things that are not structures yet, Where new code belongs (+7 more)

### Community 146 - "RagdollTests"
Cohesion: 0.16
Nodes (9): GPUPhysicsGrab, GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint (+1 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Particles.metal"
Cohesion: 0.30
Nodes (22): constant, device, kernel, uint, particleBasis(), particleBeginKernel(), particleChildSeed(), particleColor() (+14 more)

### Community 149 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 150 - "QuartzCore"
Cohesion: 0.17
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (24): OptionSet, Parts, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+16 more)

### Community 152 - "Pipelines"
Cohesion: 0.07
Nodes (33): Where things are, ComputePass, MTLHeap, MTLComputePipelineState, Step, FluidGPU, .summary, Steps (+25 more)

### Community 153 - "PlantEditorTests"
Cohesion: 0.11
Nodes (8): PlantMutate, Root, SplitMix64, Host, PlantEditorTests, Root, URL, Void

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Where things are"
Cohesion: 0.14
Nodes (12): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, Habitat, Ramp, Float, SIMD2 (+4 more)

### Community 156 - "Images"
Cohesion: 0.18
Nodes (3): 6. Math, Modes, Images

### Community 157 - "CameraTrack"
Cohesion: 0.09
Nodes (15): CameraTrack, .duration, Key, Float, ShowcaseLook, Stage, crypt, forge (+7 more)

### Community 158 - "compositeKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 159 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 160 - "TraceScene"
Cohesion: 0.06
Nodes (34): instance_acceleration_structure, RTPart, primitive_acceleration_structure, texture2d_array, uint2, TraceScene, clusterInstance, clusters (+26 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.18
Nodes (21): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit() (+13 more)

### Community 162 - "AppKit"
Cohesion: 0.17
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "CurveEditor"
Cohesion: 0.22
Nodes (12): CGPoint, DragGesture, CurveEditor, .canvas, .points, .presetTitle, LinearColorPicker, .body (+4 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - ".vgdebug"
Cohesion: 0.12
Nodes (11): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Where things are, Offscreen rendering in MetalRenderer, Recipes (+3 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "float3"
Cohesion: 0.31
Nodes (9): float3, float3x3, float4x4, int3, particleCurl(), particleGradient(), particleMeshTransform(), particleNoise() (+1 more)

### Community 170 - "liquidKernel"
Cohesion: 0.16
Nodes (18): liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device, float3 (+10 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "dot"
Cohesion: 0.08
Nodes (16): Float16, simd_double3x3, Atmosphere, LoadError, unreadable, SkyImage, Float, Set (+8 more)

### Community 174 - "SceneSettings"
Cohesion: 0.06
Nodes (19): GPUMesh, UInt64, SceneSettings, SIMD2, ForestTests, PlantTracingTests, MTLCommandQueue, MTLDevice (+11 more)

### Community 175 - "RendererError"
Cohesion: 0.12
Nodes (13): CustomStringConvertible, Error, GLTFError, .description, MTLDevice, RendererError, .description, missingFunction (+5 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "VGStreamer"
Cohesion: 0.20
Nodes (9): Group, Float, MTLBuffer, MTLDevice, UInt32, VGStreamer, .groupCount, .isSettled (+1 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - ".init"
Cohesion: 0.22
Nodes (7): LoadStep, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, MTLCommandQueue, MTLDevice

### Community 181 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 182 - ".icosphere"
Cohesion: 0.18
Nodes (3): MeshGeometry, UInt32, SDFTests

### Community 183 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "VoxelGrids"
Cohesion: 0.14
Nodes (18): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, MTLResource (+10 more)

### Community 186 - "PhysicsWorld"
Cohesion: 0.07
Nodes (28): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+20 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".stages"
Cohesion: 0.20
Nodes (12): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLTexture (+4 more)

### Community 189 - "Key"
Cohesion: 0.24
Nodes (6): Key, PipelineCache, .count, PipelineCacheTests, UInt32, Value

### Community 190 - "ParticleCounts"
Cohesion: 0.15
Nodes (13): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+5 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "LumenSDFHit"
Cohesion: 0.29
Nodes (7): LumenSDFHit, hit, id, local, normal, position, t

### Community 193 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 194 - "PhysicsJoint"
Cohesion: 0.25
Nodes (8): PhysicsJoint, anchorA, anchorB, axisA, axisB, info, referenceA, referenceB

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "ParticleTrailPose"
Cohesion: 0.33
Nodes (6): ParticleTrailPose, camera, emitters, points, step, trails

### Community 197 - "ParticleLayerParams"
Cohesion: 0.50
Nodes (4): ParticleLayerParams, detail, jitter, size

### Community 198 - "SettingsStore"
Cohesion: 0.22
Nodes (4): base, SettingsStore, Any, DispatchWorkItem

### Community 199 - "Key"
Cohesion: 0.14
Nodes (11): CodingKey, Foliage.Curve, Key, crown, linear, points, taper, Decoder (+3 more)

### Community 200 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 201 - "PlantGoldenTests"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 202 - "WorldTile"
Cohesion: 0.10
Nodes (24): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+16 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - ".requestLevels"
Cohesion: 0.19
Nodes (8): MTLRegion, MTLSparseTextureMappingMode, mappings, SparseMapping, MTLPixelFormat, MTLSize, MTLTexture, TextureUpload

### Community 207 - "Terrain"
Cohesion: 0.29
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
Cohesion: 0.13
Nodes (17): float4, uint4, Particle, info, position, velocity, ParticleEvent, a (+9 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "ParticleStep"
Cohesion: 0.11
Nodes (21): thread, particleCollide(), ParticleCollider, a, b, particleCollideScene(), particleCollideShape(), ParticleStep (+13 more)

### Community 220 - "Clip"
Cohesion: 0.23
Nodes (8): .body, Clip, graft, habitat, leaves, level, look, Clipboard

### Community 221 - "RasterScene"
Cohesion: 0.28
Nodes (5): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLTexture

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "SurfaceKind"
Cohesion: 0.17
Nodes (12): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+4 more)

### Community 224 - "LightKind"
Cohesion: 0.20
Nodes (10): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+2 more)

### Community 225 - ".addFleshCharacter"
Cohesion: 0.43
Nodes (3): Float, float4x4, SDFShape

### Community 226 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 227 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 228 - "TextureStreamWork"
Cohesion: 0.29
Nodes (4): MTLCommandBuffer, TextureStreamWork, URL, TextureStreamerTests

### Community 229 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 231 - "BuildingTier"
Cohesion: 0.22
Nodes (7): BuildingTier, .top, RoofKind, flat, gabled, hipped, mansard

### Community 232 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 233 - ".clusterize"
Cohesion: 0.47
Nodes (5): LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 234 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 235 - ".addHair"
Cohesion: 0.27
Nodes (6): HairStyle, Float, UInt32, SplitMix, Float, UInt64

### Community 236 - "uint"
Cohesion: 0.47
Nodes (10): constant, kernel, uint, vsmAllocKernel(), vsmChunksKernel(), vsmFreeKernel(), vsmResetKernel(), vsmSettleKernel() (+2 more)

### Community 238 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 239 - "boxCandidate"
Cohesion: 0.48
Nodes (7): boxCandidate(), clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 240 - "particleOverlayKernel"
Cohesion: 0.20
Nodes (19): Built, Particles: handoff (branch claude/init-branch-94ae07), To do on the M4 Max, Traps found, float2, read, read_write, sample (+11 more)

### Community 241 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 242 - "VGBlas"
Cohesion: 0.29
Nodes (7): VGBlas, attrs, pad0, pad1, pad2, triangles, tris

### Community 243 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 244 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 245 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 247 - "ParticleDistortParams"
Cohesion: 0.40
Nodes (5): ParticleDistortParams, count, emitters, first, time

### Community 248 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 249 - "Detail"
Cohesion: 0.67
Nodes (3): Detail, flat, full

## Knowledge Gaps
- **1697 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1692 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2298 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **17 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `AABB`, `GLTFLoader`, `RenderSettings`, `.simplify`, `Bool`, `RenderView`, `FramePlan`, `ParticlesGPU`, `Metal4Frame`, `translate`, `ParticleEmitter`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `PlantEditorModel`, `Kernel`, `SettingsPanel`, `Renderer`, `Build`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `.write`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `RendererController`, `SceneKind`, `ParticleMath`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `Int32`, `RenderPass`, `RasterClusters`, `SDFShape`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `View`, `Double`, `Float`, `FoliageTextures`, `ProceduralTextures`, `ParticleTextures`, `Upscaler`, `FluidTests`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `ParticleTests`, `String`, `Benchmark`, `.library`, `Map`, `PlantCatalog`, `BuildingAssembler`, `Scene`, `HairTests`, `Foliage`, `Float`, `PlantTracing`, `ParticleSystem`, `Camera`, `SettingsTableTests`, `Slot`, `Config`, `WindFrame`, `FrameEncoder`, `SIMD3`, `VoxelLOD`, `VirtualMesh`, `Rect`, `RagdollTests`, `.buildStress`, `Pipelines`, `Curve`, `Images`, `CurveEditor`, `FoliageRuntimeTests`, `dot`, `SceneSettings`, `RendererError`, `VGStreamer`, `.init`, `.icosphere`, `VoxelGrids`, `PhysicsWorld`, `.stages`, `Key`, `WorldTile`, `.requestLevels`, `Terrain`, `RasterScene`, `SurfaceKind`, `LightKind`, `.addFleshCharacter`, `TextureStreamWork`, `.clusterize`, `.addHair`, `.used`, `Detail`, `.snapshot`?**
  _High betweenness centrality (0.297) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `AABB`, `SettingsTableTests`, `GLTFLoader`, `RenderSettings`, `Int`, `Config`, `FrameEncoder`, `Bool`, `RenderView`, `SIMD3`, `FramePlan`, `VirtualMesh`, `Metal4Frame`, `translate`, `ParticleEmitter`, `TextureStreamer`, `Pipelines`, `PlantEditorTests`, `Curve`, `PlantEditorModel`, `Images`, `Kernel`, `Renderer`, `SettingsPanel`, `CameraTrack`, `SkinnedCharacter`, `Where things are`, `GPUTypes.swift`, `CurveEditor`, `SectionFile`, `.write`, `SettingsTable.swift`, `SceneBuffers`, `dot`, `SceneSettings`, `RendererError`, `VGStreamer`, `FBXFile`, `RendererController`, `SceneKind`, `.init`, `VoxelGrids`, `MuscleAtlas`, `SettingsStore`, `Key`, `VirtualTracing`, `PlantGoldenTests`, `WorldTile`, `RasterClusters`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `View`, `Double`, `Capabilities`, `FoliageTextures`, `Clip`, `Upscaler`, `VirtualGeometry`, `FluidTests`, `KernelVariantsTests`, `EnvVariable`, `ParticleTests`, `Benchmark`, `.library`, `PlantCatalog`, `CacheTests`, `Scene`, `Foliage`?**
  _High betweenness centrality (0.102) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `pcgHash`, `restirGIInitialKernel`, `KernelVariantsTests`, `traceKernel`, `.draw`, `Pipelines`, `Kernel`?**
  _High betweenness centrality (0.098) - this node is a cross-community bridge._
- **Are the 50 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 50 INFERRED edges - model-reasoned connections that need verification._
- **Are the 27 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 27 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1697 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `AABB` be split into smaller, more focused modules?**
  _Cohesion score 0.06340326340326341 - nodes in this community are weakly interconnected._