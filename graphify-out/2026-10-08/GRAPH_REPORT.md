# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 274 files · ~1,334,360 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 8118 nodes · 25439 edges · 267 communities (243 shown, 24 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 4034 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4d80d45e`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- SplitMix64
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- View
- .simplify
- Fluid.metal
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- VFXEditorModel
- RenderPass4
- translate
- ParticleEmitter
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- ParticlesGPU
- LightSampling.metal
- SIMD4
- PlantEditorModel
- Kernel
- SettingsPanel
- Renderer
- String
- traceKernel
- restirSpatialKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- EnvVariable
- CaseIterable
- sin
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
- reflectionKernel
- Images
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
- CityTests
- .d
- simd
- RenderPass
- Int
- SDFShape
- BVHBuilder
- Pipelines
- ab.sh
- LoadActivity
- lumenTraceKernel
- Intersect.metal
- VirtualBLAS
- PlantParam
- Double
- Capabilities
- Foliage
- FoliageTextures
- .sources
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- quatRotate
- PhysicsTests
- MuscleTests
- Footprint
- float3
- .writeFrameData
- SoftModel
- uint4
- Building
- BuildingStyle
- SettingsTableTests
- ParticleTests
- .load
- Benchmark
- .library
- BlueNoise
- PlantCatalog
- compositeKernel
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- Scene
- HairTests
- Flora
- same.sh
- VFXEffect
- baseline.sh
- PlantTracing
- ParticleSystem
- VFXOpKind
- Raster.metal
- Int32
- .node
- lumenCardRadiosityKernel
- World
- Foliage.metal
- VFXBlockKind
- LoadingOverlay
- VFXHostingView
- FrameEncoder
- Float
- VoxelLOD
- .meshes
- FluidSurface.metal
- RasterClusters.metal
- .writeDescriptors
- CityPlan
- .draw
- RagdollTests
- VSMCounters
- Map
- Slot
- QuartzCore
- .buildStress
- ComputePass
- PlantEditorTests
- Curve
- Where things are
- RendererController
- Config
- GPUMaterial
- Habitat
- TraceScene
- SurfaceKind
- AppKit
- RasterVGParams
- related.sh
- CurveEditor
- Heavens
- .env
- VGParams
- ParticleSim.metal
- liquidKernel
- FoliageRuntimeTests
- VSM.metal
- VSMTargets
- SceneSettings
- .gpuCut
- VSMView
- LumenGlobalSDF
- VSMClusterArgs
- VSMScene
- .init
- SceneShading
- float4
- SkyParams
- VSMParams
- VoxelGrids
- PhysicsWorld
- RasterParams
- .stages
- Key
- ParticleEmitter
- VSMInstance
- .begin
- device
- PhysicsJoint
- RasterCounters
- VFXTests
- VFXCompiler
- SettingsStore
- Key
- RasterInstance
- PlantGoldenTests
- WorldTile
- .end
- PhysicsGrab
- PhysPush
- Buffer
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- VFXLayout
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- .used
- Clip
- RasterScene
- PhysicsSkinAttach
- VFXType
- VFXInterpreter
- float3
- PostParams
- .capture
- KernelVariantsTests
- Metal4Frame
- RasterSceneTests
- .addCloth
- float4
- .clusterize
- PlantSpecies.swift
- .addHair
- uint
- ParticleStep
- Stage
- .write
- particleLightKernel
- Types.metal
- Particles
- VFXEditKind
- Host
- Bool
- .init
- .commit
- VGRasterInstance
- ParticleCounts
- Flora
- .encoder
- RenderThread
- VFXEmitterInfo
- .updatePrimitives
- WorldPlace
- .key
- XCTestCase
- Foliage.Curve
- Liquids
- .mark
- .useResource
- Layout
- Solvers
- LightMotion
- SIMD3
- .bytes

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 478 edges
2. `Scene` - 330 edges
3. `Renderer` - 274 edges
4. `PhysicsWorld` - 272 edges
5. `SIMD4` - 186 edges
6. `Kernel` - 167 edges
7. `Foliage` - 151 edges
8. `simd` - 145 edges
9. `Benchmark` - 116 edges
10. `RenderSettings` - 109 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Traps found` --references--> `VFXTests`  [INFERRED]
  .claude/notes/vfx-editor-handoff.md → Tests/MetalRendererTests/VFXTests.swift

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

## Communities (267 total, 24 thin omitted)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (47): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+39 more)

### Community 3 - "RenderSettings"
Cohesion: 0.09
Nodes (53): Codable, Equatable, AgeRule, Ages, CountRule, GrassPatch, Look, Palette (+45 more)

### Community 4 - "Lights.metal"
Cohesion: 0.08
Nodes (67): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+59 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.08
Nodes (58): half4, float2, float3, float4, primitive_acceleration_structure, read, SCENE_ACCEL, texture2d (+50 more)

### Community 6 - "View"
Cohesion: 0.09
Nodes (41): Shape, Binding, VFXCollider, .body, CGPoint, CGSize, DragGesture, Float (+33 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "SettingsTable"
Cohesion: 0.08
Nodes (30): Bound, F, on, .reservoirCount, Control, checkbox, custom, popup (+22 more)

### Community 11 - "RenderView"
Cohesion: 0.05
Nodes (32): AnyObject, CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, FrameOutput, Headless, LayerSurface (+24 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.16
Nodes (15): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+7 more)

### Community 14 - "VFXEditorModel"
Cohesion: 0.08
Nodes (22): VFXCatalog, .body, Clip, CGSize, DispatchWorkItem, URL, Void, VFXEditorHost (+14 more)

### Community 15 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 16 - "translate"
Cohesion: 0.17
Nodes (14): scale(), translate(), ParticleCollider, FogVolume, .gpu, LightPose, Kit, Float (+6 more)

### Community 17 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): Kind, Flags, Orientation, axis, .code, rayFacing, velocity, world (+15 more)

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
Nodes (76): distance, makeRay(), constant, device, float2, float3, float4, kernel (+68 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.10
Nodes (21): MTLRegion, MTLSparseTextureMappingMode, SparseMapping, MTLBuffer, MTLCommandBuffer, MTLHeap, MTLPixelFormat, MTLSize (+13 more)

### Community 24 - "ParticlesGPU"
Cohesion: 0.10
Nodes (21): Part, Build, Counter, Part, ParticlesGPU, .hasPrograms, .trailShape, Float (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (60): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+52 more)

### Community 26 - "SIMD4"
Cohesion: 0.11
Nodes (20): GPUJoint, .worldToView, UInt32, .gpuNodes, Clip, .duration, .loopKeys, Level (+12 more)

### Community 27 - "PlantEditorModel"
Cohesion: 0.08
Nodes (21): Reading the table, ObservableObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty (+13 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (148): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+140 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (75): To do on the M4 Max, 8. Pipelines and resources, MetalKit, SkyImage, Set, GPUPostParams, GPURegirParams, done (+67 more)

### Community 31 - "String"
Cohesion: 0.05
Nodes (32): MTLBlitCommandEncoder, MTLRenderPassDescriptor, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder, Float, .envText (+24 more)

### Community 32 - "traceKernel"
Cohesion: 0.06
Nodes (76): 3. Occupancy and registers: the default suspect for big kernels, metal_raytracing, metal_stdlib, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0() (+68 more)

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
Cohesion: 0.09
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.09
Nodes (18): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, GeneratedCache, Hasher, SectionFile, .array, Data (+10 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 42 - "CaseIterable"
Cohesion: 0.04
Nodes (70): CaseIterable, Body, muscles, skin, .title, DirectLightMode, auto, exact (+62 more)

### Community 43 - "sin"
Cohesion: 0.10
Nodes (11): Atmosphere, Float, .front, HairBSDF, Float, .forward, UnsafeMutableBufferPointer, MeshGeometry (+3 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (36): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+28 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.13
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.06
Nodes (28): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindowDelegate, AppDelegate, Any, Notification, NSWindow (+20 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - "FBXFile"
Cohesion: 0.06
Nodes (44): Compression, IteratorProtocol, Sequence, simd_double4x4, simd_quatd, Children, Connection, Contents (+36 more)

### Community 51 - "DebugPanel"
Cohesion: 0.07
Nodes (21): NSColor, NSStackView, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, Section (+13 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "ParticleMath"
Cohesion: 0.17
Nodes (10): GPUParticleRender, Fragment, ParticleEvent, .seed, .spawn, ParticleMath, Rng, Float (+2 more)

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
Nodes (41): .parent, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+33 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.03
Nodes (122): Material, glassKernel(), glassReflection(), constant, device, float3, kernel, read (+114 more)

### Community 62 - "Images"
Cohesion: 0.16
Nodes (3): 6. Math, Modes, Images

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "AABB"
Cohesion: 0.06
Nodes (32): Int8, AABB, .area, .centroid, .isEmpty, float4x4, GLTFModel, .bounds (+24 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.06
Nodes (31): MTLComputePipelineState, .virtualGeometryChanged, Content, PlantKey, Float, MTLAccelerationStructure, MTLBuffer, MTLDevice (+23 more)

### Community 74 - ".d"
Cohesion: 0.12
Nodes (9): Float16, SDFVolume, .hi, Float, MeshGeometry, lerp, SDFTests, Float (+1 more)

### Community 76 - "RenderPass"
Cohesion: 0.09
Nodes (9): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, MTLResource, MTLResourceUsage (+1 more)

### Community 77 - "Int"
Cohesion: 0.04
Nodes (55): PrimitiveRefit, MTLAccelerationStructure, MTLPrimitiveAccelerationStructureDescriptor, Range, Frame, MTLResource, Params, RasterClusters (+47 more)

### Community 78 - "SDFShape"
Cohesion: 0.12
Nodes (23): Node, .transform, Op, intersect, subtract, union, Primitive, box (+15 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "Pipelines"
Cohesion: 0.19
Nodes (18): MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Pipelines, .lumen (+10 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.15
Nodes (11): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Snapshot, .isIdle (+3 more)

### Community 83 - "lumenTraceKernel"
Cohesion: 0.05
Nodes (87): int4, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams, grid (+79 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.05
Nodes (97): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), boxCandidate(), candidate() (+89 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.15
Nodes (20): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+12 more)

### Community 86 - "PlantParam"
Cohesion: 0.07
Nodes (37): L, .body, EditorGroup, ParamRow, .body, ParamRows, .body, Root (+29 more)

### Community 87 - "Double"
Cohesion: 0.18
Nodes (7): Double, Block, City, Highway, Roadbeds, Float, SIMD2

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.07
Nodes (42): Card, Level, Plant, Skeleton, Float, Bone, Card, Carve (+34 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - ".sources"
Cohesion: 0.19
Nodes (10): Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32, UInt8 (+2 more)

### Community 92 - "ParticleTextures"
Cohesion: 0.11
Nodes (23): Aux, flameMotion, .layer, smokeBack, smokeLight, Kind, bubble, flame (+15 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.11
Nodes (11): Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, FluidTests, Float (+3 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.13
Nodes (7): GPUPhysicsGrab, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (12): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, MuscleTests (+4 more)

### Community 99 - "Footprint"
Cohesion: 0.17
Nodes (12): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .cover (+4 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - ".writeFrameData"
Cohesion: 0.10
Nodes (10): GPUFogParams, .reflectionPassFlags, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, Float, UnsafeBufferPointer (+2 more)

### Community 102 - "SoftModel"
Cohesion: 0.06
Nodes (33): ArraySlice, GPUPhysicsParticle, GPUSoftVertex, .particleCellSize, Flesh, MuscleSpec, Side, back (+25 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.17
Nodes (10): Building, BuildingGenerator, Module, SurfaceMaterial, .uvScale, Data, float4x4, BuildingTests (+2 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "SettingsTableTests"
Cohesion: 0.12
Nodes (8): Settings: `SettingsTable.swift`, SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 107 - "ParticleTests"
Cohesion: 0.14
Nodes (9): Key, ParticleTests, Float, MTLCommandQueue, MTLDevice, StaticString, UInt, UInt32 (+1 more)

### Community 108 - ".load"
Cohesion: 0.13
Nodes (11): CustomStringConvertible, Error, LoadError, unreadable, Failure, ShaderSource, URL, VFXError (+3 more)

### Community 109 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 110 - ".library"
Cohesion: 0.08
Nodes (23): Mesh, RawRepresentable, Age, mature, sapling, young, Part, Plant (+15 more)

### Community 111 - "BlueNoise"
Cohesion: 0.30
Nodes (5): BlueNoise, SplitMix64, Float, UInt64, URL

### Community 112 - "PlantCatalog"
Cohesion: 0.08
Nodes (18): .key, .savedDef, PlantCatalog, .count, .covers, File, Foliage.SpeciesDef, .fingerprint (+10 more)

### Community 113 - "compositeKernel"
Cohesion: 0.05
Nodes (85): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+77 more)

### Community 114 - "Metal"
Cohesion: 0.09
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.32
Nodes (9): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+1 more)

### Community 119 - "Scene"
Cohesion: 0.04
Nodes (62): GPUEmissiveTriangle, GPUMesh, UInt64, Assembly, Bone, BorrowedLight, BorrowedMesh, CityLight (+54 more)

### Community 120 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 121 - "Flora"
Cohesion: 0.12
Nodes (14): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+6 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "VFXEffect"
Cohesion: 0.07
Nodes (36): Phase 1 (graph model, code generator, compile, interpreter, ports): done, at check-in 1, Identifiable, Kind, plume, vortex, ParticleCollider, SIMD2, VFXCurve (+28 more)

### Community 125 - "PlantTracing"
Cohesion: 0.12
Nodes (19): 7. Acceleration structures and ray tracing, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder (+11 more)

### Community 126 - "ParticleSystem"
Cohesion: 0.08
Nodes (21): GPUVFXEmitter, ParticleCollider, box, .gpu, plane, shape, sphere, ParticleField (+13 more)

### Community 127 - "VFXOpKind"
Cohesion: 0.04
Nodes (50): VFXOpKind, abs, add, age, ageOverLife, and, clamp, colorValue (+42 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "Int32"
Cohesion: 0.07
Nodes (34): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, Pose (+26 more)

### Community 130 - ".node"
Cohesion: 0.12
Nodes (21): Float, Void, .spec, Hooks, Op, attribute, lifetime, position (+13 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (49): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+41 more)

### Community 132 - "World"
Cohesion: 0.14
Nodes (13): Float, World, .anchorTile, .start, Ground, Placement, Road, SplitMix64 (+5 more)

### Community 133 - "Foliage.metal"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "VFXBlockKind"
Cohesion: 0.07
Nodes (29): VFXBlockKind, billboard, burst, collide, color, curl, distortion, drag (+21 more)

### Community 135 - "LoadingOverlay"
Cohesion: 0.10
Nodes (16): NSFont, NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item (+8 more)

### Community 136 - "VFXHostingView"
Cohesion: 0.18
Nodes (7): AnyView, NSHostingView, Any, CGPoint, NSEvent, VFXHostingView, .acceptsFirstResponder

### Community 137 - "FrameEncoder"
Cohesion: 0.06
Nodes (30): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp (+22 more)

### Community 138 - "Float"
Cohesion: 0.10
Nodes (17): simd_double3x3, GPUPhysicsShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+9 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - ".meshes"
Cohesion: 0.15
Nodes (16): MTLDevice, Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32 (+8 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.37
Nodes (19): fluidCorner(), fluidSurfaceBlurKernel(), fluidSurfaceCell(), fluidSurfaceClearKernel(), fluidSurfaceCoords(), fluidSurfaceCountKernel(), fluidSurfaceEdges(), fluidSurfaceNode() (+11 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - ".writeDescriptors"
Cohesion: 0.24
Nodes (6): Tests, Float, float3x3, float4x4, UInt32, Wind

### Community 144 - "CityPlan"
Cohesion: 0.10
Nodes (29): Block, CityPlan, Edge, open, party, street, Lamp, Lot (+21 more)

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (25): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants, Launch time (+17 more)

### Community 146 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Map"
Cohesion: 0.13
Nodes (14): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, FluidSurface, dims, field (+6 more)

### Community 149 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (5): Combine, Element, MetalFX, QuartzCore, Array

### Community 151 - ".buildStress"
Cohesion: 0.16
Nodes (12): Parts, Hall, Loop, Props, Float, float4x4, SIMD2, Zone (+4 more)

### Community 152 - "ComputePass"
Cohesion: 0.08
Nodes (28): ComputePass, MTLHeap, MTLSize, MTLComputePipelineState, Step, FluidGPU, .summary, Steps (+20 more)

### Community 153 - "PlantEditorTests"
Cohesion: 0.11
Nodes (8): PlantMutate, Root, SplitMix64, Host, PlantEditorTests, Root, URL, Void

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Where things are"
Cohesion: 0.20
Nodes (6): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests, Void

### Community 156 - "RendererController"
Cohesion: 0.10
Nodes (20): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles, .plantStats (+12 more)

### Community 157 - "Config"
Cohesion: 0.13
Nodes (8): Benchmark modes: `Benchmark+Modes.swift`, CameraTrack, .duration, Config, Key, Float, ShowcaseLook, Float

### Community 158 - "GPUMaterial"
Cohesion: 0.27
Nodes (7): GPUMaterial, Assembler, Draft, Data, float4x4, UInt8, Void

### Community 159 - "Habitat"
Cohesion: 0.26
Nodes (9): Cover, Habitat, Ramp, Float, SIMD2, UInt32, UInt64, TreePicker (+1 more)

### Community 160 - "TraceScene"
Cohesion: 0.04
Nodes (48): instance_acceleration_structure, RTPart, BVHNode, hi0, hi1, lo0, lo1, ClusterBox (+40 more)

### Community 161 - "SurfaceKind"
Cohesion: 0.17
Nodes (12): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+4 more)

### Community 162 - "AppKit"
Cohesion: 0.13
Nodes (5): AppKit, CoreGraphics, ImageIO, SwiftUI, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "CurveEditor"
Cohesion: 0.22
Nodes (12): CurveEditor, .canvas, .points, .presetTitle, LinearColorPicker, .body, CGPoint, CGSize (+4 more)

### Community 166 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 167 - ".env"
Cohesion: 0.11
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "ParticleSim.metal"
Cohesion: 0.27
Nodes (24): constant, device, kernel, uint, particleBeginKernel(), particleChildSeed(), particleColor(), particleEmitKernel() (+16 more)

### Community 170 - "liquidKernel"
Cohesion: 0.15
Nodes (19): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device (+11 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 174 - "SceneSettings"
Cohesion: 0.06
Nodes (16): Where things are, Scene kinds: `SceneKind` in `Settings.swift`, made, SceneSettings, SIMD2, URL, PlantTracingTests, MTLCommandQueue (+8 more)

### Community 175 - ".gpuCut"
Cohesion: 0.31
Nodes (8): GPUCut, Error, float4x4, MTLComputePipelineState, MTLDevice, Set, UInt32, VGCutTests

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - ".init"
Cohesion: 0.17
Nodes (9): .isCancelled, LoadStep, .isCancelled, Entry, Level, Data, MTLCommandQueue, MTLDevice (+1 more)

### Community 181 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 182 - "float4"
Cohesion: 0.09
Nodes (23): float4, uint4, Particle, info, position, velocity, ParticleEvent, a (+15 more)

### Community 183 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "VoxelGrids"
Cohesion: 0.16
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 186 - "PhysicsWorld"
Cohesion: 0.07
Nodes (32): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, dot (+24 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".stages"
Cohesion: 0.09
Nodes (23): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+15 more)

### Community 189 - "Key"
Cohesion: 0.48
Nodes (4): Key, PipelineCache, .count, Value

### Community 190 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+15 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 193 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 194 - "PhysicsJoint"
Cohesion: 0.25
Nodes (8): PhysicsJoint, anchorA, anchorB, axisA, axisB, info, referenceA, referenceB

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "VFXTests"
Cohesion: 0.21
Nodes (8): Key, MTLCommandQueue, MTLDevice, StaticString, UInt, UInt32, Void, VFXTests

### Community 197 - "VFXCompiler"
Cohesion: 0.18
Nodes (15): Hashable, .vfxSetup, Entry, building, failed, ready, Key, ParticleKernels (+7 more)

### Community 198 - "SettingsStore"
Cohesion: 0.22
Nodes (4): base, SettingsStore, Any, DispatchWorkItem

### Community 199 - "Key"
Cohesion: 0.10
Nodes (19): CodingKey, Key, crown, linear, points, taper, Key, whorled (+11 more)

### Community 200 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 201 - "PlantGoldenTests"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 202 - "WorldTile"
Cohesion: 0.14
Nodes (15): .time, Chunk, .triangles, ChunkRecord, Light, Float, SIMD2, UInt32 (+7 more)

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
Cohesion: 0.22
Nodes (7): Float, SIMD2, UInt32, UInt64, Terrain, .cell, ForestTests

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

### Community 213 - "VFXLayout"
Cohesion: 0.05
Nodes (49): Next: phase 3 (preview tools, the stage's backdrops, gizmos), Phase 2 (the editor window): done, at check-in 2, The user's choices, Traps found, VFX editor: handoff (branch claude/init-branch-94ae07, PR #54), Color, Path, CGFloat (+41 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 220 - "Clip"
Cohesion: 0.23
Nodes (8): .body, Clip, graft, habitat, leaves, level, look, Clipboard

### Community 221 - "RasterScene"
Cohesion: 0.12
Nodes (14): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+6 more)

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "VFXType"
Cohesion: 0.09
Nodes (21): Gesture, Float, VFXBlockSpec, VFXFamily, attribute, curve, input, logic (+13 more)

### Community 224 - "VFXInterpreter"
Cohesion: 0.17
Nodes (11): ParticleEvent, GPUParticle, GPUParticleCollider, GPUParticleEmitter, GPUParticleField, GPUParticleStep, .gpuEmitters, Float (+3 more)

### Community 225 - "float3"
Cohesion: 0.27
Nodes (10): float3, float3x3, float4x4, int3, particleCurl(), particleGradient(), particleMeshTransform(), particleNoise() (+2 more)

### Community 226 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 227 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 228 - "KernelVariantsTests"
Cohesion: 0.25
Nodes (3): Pipelines: `Pipelines.swift`, KernelVariantsTests, UInt32

### Community 229 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 230 - "RasterSceneTests"
Cohesion: 0.31
Nodes (3): RasterSceneTests, Float, MeshGeometry

### Community 231 - ".addCloth"
Cohesion: 0.22
Nodes (9): .cells, Cloth, Set, SkinOptions, SkinShell, Float, MeshGeometry, SIMD2 (+1 more)

### Community 232 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 233 - ".clusterize"
Cohesion: 0.40
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

### Community 237 - "ParticleStep"
Cohesion: 0.11
Nodes (24): SCENE_ACCEL, thread, particleBasis(), particleBirth(), particleCollide(), ParticleCollider, a, b (+16 more)

### Community 238 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 239 - ".write"
Cohesion: 0.33
Nodes (4): .cacheURL, CacheFile, Data, URL

### Community 240 - "particleLightKernel"
Cohesion: 0.11
Nodes (37): Built, Particles: handoff (branch claude/init-branch-94ae07), To do on the M4 Max, Traps found, constant, device, float2, float3 (+29 more)

### Community 241 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 242 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 243 - "VFXEditKind"
Cohesion: 0.40
Nodes (4): VFXEditKind, code, rebuild, values

### Community 245 - "Bool"
Cohesion: 0.10
Nodes (14): .area, Ends, Float, Shape, courtyard, l, rect, t (+6 more)

### Community 247 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 248 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 249 - "ParticleCounts"
Cohesion: 0.15
Nodes (13): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+5 more)

### Community 251 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 256 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 257 - "VFXEmitterInfo"
Cohesion: 0.22
Nodes (9): VFXEmitterInfo, attributes, hooks, pad0, pad1, pad2, params, program (+1 more)

### Community 258 - ".updatePrimitives"
Cohesion: 0.29
Nodes (4): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder

### Community 260 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 264 - "XCTestCase"
Cohesion: 0.22
Nodes (4): GLTFLoaderTests, StressSceneTests, VGStreamerTests, XCTestCase

### Community 265 - "Foliage.Curve"
Cohesion: 0.33
Nodes (3): Foliage.Curve, Decoder, Encoder

### Community 266 - "Liquids"
Cohesion: 0.33
Nodes (6): Liquids, all, blood, honey, .title, water

### Community 269 - "Layout"
Cohesion: 0.40
Nodes (5): Layout, lineup, mutate, single, .title

### Community 270 - "Solvers"
Cohesion: 0.40
Nodes (5): Solvers, auto, mpm, pbf, .title

### Community 275 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 277 - "SIMD3"
Cohesion: 0.06
Nodes (38): Darwin, OptionSet, .triangleCount, Camera, .right, rotate(), Float, float4x4 (+30 more)

## Knowledge Gaps
- **1844 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1839 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2481 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **24 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `SplitMix64`, `GLTFLoader`, `RenderSettings`, `View`, `.simplify`, `SettingsTable`, `RenderView`, `FramePlan`, `RenderPass4`, `translate`, `ParticleEmitter`, `LightTable`, `TextureStreamer`, `ParticlesGPU`, `SIMD4`, `PlantEditorModel`, `Kernel`, `SettingsPanel`, `Renderer`, `String`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `EnvVariable`, `CaseIterable`, `sin`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `ParticleMath`, `MuscleAtlas`, `Images`, `AABB`, `VirtualTracing`, `CityTests`, `.d`, `RenderPass`, `SDFShape`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `PlantParam`, `Double`, `Foliage`, `FoliageTextures`, `.sources`, `ParticleTextures`, `Upscaler`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `Footprint`, `.writeFrameData`, `SoftModel`, `Building`, `SettingsTableTests`, `ParticleTests`, `Benchmark`, `.library`, `BlueNoise`, `PlantCatalog`, `BuildingAssembler`, `.named`, `Scene`, `HairTests`, `Flora`, `VFXEffect`, `PlantTracing`, `ParticleSystem`, `Int32`, `.node`, `World`, `LoadingOverlay`, `FrameEncoder`, `Float`, `VoxelLOD`, `.meshes`, `.writeDescriptors`, `CityPlan`, `.draw`, `RagdollTests`, `Slot`, `QuartzCore`, `.buildStress`, `ComputePass`, `Curve`, `RendererController`, `Config`, `GPUMaterial`, `Habitat`, `SurfaceKind`, `CurveEditor`, `FoliageRuntimeTests`, `VSMTargets`, `SceneSettings`, `.gpuCut`, `LumenGlobalSDF`, `.init`, `VoxelGrids`, `PhysicsWorld`, `.stages`, `Key`, `VFXTests`, `WorldTile`, `Buffer`, `Terrain`, `VFXLayout`, `.used`, `RasterScene`, `VFXInterpreter`, `Metal4Frame`, `RasterSceneTests`, `.addCloth`, `.clusterize`, `.addHair`, `Bool`, `.init`, `.commit`, `Flora`, `.encoder`, `.updatePrimitives`, `WorldPlace`, `.key`, `XCTestCase`, `Liquids`, `Layout`, `Solvers`, `SIMD3`?**
  _High betweenness centrality (0.286) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `GLTFLoader`, `RenderSettings`, `View`, `SettingsTable`, `RenderView`, `FramePlan`, `VFXEditorModel`, `translate`, `ParticleEmitter`, `TextureStreamer`, `ParticlesGPU`, `SIMD4`, `PlantEditorModel`, `Kernel`, `SettingsPanel`, `Renderer`, `SectionFile`, `EnvVariable`, `CaseIterable`, `SceneBuffers`, `FBXFile`, `DebugPanel`, `SceneKind`, `MuscleAtlas`, `Images`, `AABB`, `VirtualTracing`, `Int`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `PlantParam`, `Capabilities`, `Foliage`, `FoliageTextures`, `Upscaler`, `Metal3Pass`, `SoftModel`, `SettingsTableTests`, `ParticleTests`, `.load`, `Benchmark`, `.library`, `PlantCatalog`, `.named`, `Scene`, `Flora`, `VFXEffect`, `ParticleSystem`, `VFXOpKind`, `Int32`, `.node`, `World`, `VFXBlockKind`, `LoadingOverlay`, `FrameEncoder`, `.meshes`, `CityPlan`, `ComputePass`, `PlantEditorTests`, `Curve`, `Where things are`, `RendererController`, `Config`, `CurveEditor`, `.env`, `SceneSettings`, `.init`, `VoxelGrids`, `PhysicsWorld`, `.begin`, `VFXTests`, `VFXCompiler`, `SettingsStore`, `Key`, `PlantGoldenTests`, `WorldTile`, `Buffer`, `VFXLayout`, `Clip`, `VFXType`, `KernelVariantsTests`, `Bool`, `.commit`, `.encoder`, `.updatePrimitives`, `Liquids`, `.mark`, `Layout`, `Solvers`, `SIMD3`?**
  _High betweenness centrality (0.157) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `GLTFLoader`, `RenderSettings`, `View`, `.simplify`, `SettingsTable`, `RenderView`, `FramePlan`, `VFXEditorModel`, `translate`, `ParticleEmitter`, `TextureStreamer`, `ParticlesGPU`, `PlantEditorModel`, `SettingsPanel`, `Renderer`, `String`, `EnvVariable`, `CaseIterable`, `sin`, `SceneBuffers`, `LumenScene`, `AppDelegate`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `AABB`, `VirtualTracing`, `CityTests`, `Int`, `SDFShape`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `PlantParam`, `Double`, `Foliage`, `FoliageTextures`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Footprint`, `.writeFrameData`, `SoftModel`, `Building`, `SettingsTableTests`, `.load`, `Benchmark`, `.library`, `PlantCatalog`, `BuildingAssembler`, `.named`, `Scene`, `HairTests`, `Flora`, `VFXEffect`, `PlantTracing`, `ParticleSystem`, `Int32`, `.node`, `VFXBlockKind`, `LoadingOverlay`, `VFXHostingView`, `FrameEncoder`, `VoxelLOD`, `.meshes`, `.writeDescriptors`, `CityPlan`, `RagdollTests`, `.buildStress`, `ComputePass`, `Curve`, `Where things are`, `RendererController`, `Config`, `GPUMaterial`, `Habitat`, `SurfaceKind`, `Heavens`, `.env`, `FoliageRuntimeTests`, `VSMTargets`, `SceneSettings`, `.gpuCut`, `LumenGlobalSDF`, `.init`, `VoxelGrids`, `PhysicsWorld`, `.stages`, `Key`, `VFXCompiler`, `WorldTile`, `VFXLayout`, `Clip`, `RasterScene`, `VFXType`, `VFXInterpreter`, `.capture`, `.clusterize`, `.addHair`, `.commit`, `.encoder`, `RenderThread`, `.key`, `SIMD3`?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **Are the 52 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 52 INFERRED edges - model-reasoned connections that need verification._
- **Are the 28 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 28 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1844 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `MetalGI Real-Time Ray Tracer` be split into smaller, more focused modules?**
  _Cohesion score 0.0519774011299435 - nodes in this community are weakly interconnected._