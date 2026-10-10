# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 276 files · ~1,339,697 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 8226 nodes · 25772 edges · 253 communities (236 shown, 17 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 4095 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `f88a5059`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- lumenTraceKernel
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- View
- .simplify
- Fluid.metal
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- FramePlan
- VFXEditorModel
- Metal4Frame
- translate
- .part
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- .writeFrameData
- Int
- ParticlesGPU
- LightSampling.metal
- SkinnedCharacter
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
- XCTestCase
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
- SIMD3
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- SkyParams
- reflectionKernel
- Images
- Types.metal
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
- cross
- simd
- Metal3Pass
- VirtualGeometry
- SDFShape
- FoliageTextures
- .compile
- ab.sh
- LoadActivity
- LumenSDF.metal
- uint
- VirtualBLAS
- CurveEditor
- Double
- Capabilities
- Foliage
- GizmoView
- SurfaceKind
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- .write
- Footprint
- float3
- flagOn
- SoftModel
- uint4
- Building
- BuildingStyle
- FBXError
- ParticleTests
- SkyImage
- Benchmark
- VGStreamer
- .write
- Intersect.metal
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- Config
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
- FluidSystem
- .node
- lumenCardRadiosityKernel
- Post.metal
- Foliage.metal
- VFXGizmos
- LoadingOverlay
- VFXHostingView
- GPUProfiler
- SIMD4
- VoxelLOD
- VirtualMesh
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
- Pipelines
- PlantEditorTests
- Curve
- Where things are
- RendererController
- CameraTrack
- SDFBox
- LayerSurface
- TraceScene
- Camera
- AppKit
- RasterVGParams
- related.sh
- VFXEditorPanel
- Heavens
- .vgdebug
- VGParams
- ParticleSim.metal
- liquidKernel
- FoliageRuntimeTests
- VSM.metal
- VSMTargets
- SceneBuffersTests
- RasterClusters
- VSMView
- ClusterBox
- VSMClusterArgs
- VSMScene
- PlantEditorPanel
- .scatter
- float4
- GLTFError
- VSMParams
- VoxelGrids
- PhysicsWorld
- RasterParams
- LumenGlobalSDF
- Key
- ParticleEmitter
- VSMInstance
- SDFBuffers
- device
- PhysicsJoint
- RasterCounters
- VFXTests
- VFXCompiler
- SettingsStore
- VFXParam
- RasterInstance
- PlantGoldenTests
- WorldTile
- .end
- PhysicsGrab
- PhysPush
- VFXBackdrop
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
- LumenRadiosityParams
- InstanceData
- RasterScene
- PhysicsSkinAttach
- VFXBlockKind
- VFXInterpreter
- float3
- DebugInfo
- .capture
- LumenParams
- TraversalStats
- GPUMesh
- Shape
- boxCandidate
- RTVoxels
- PlantSpecies.swift
- VGBlas
- uint
- ParticleStep
- MuscleSpec
- particleLightKernel
- VFXLive.swift
- Host
- Rect
- VGRasterInstance
- ParticleCounts
- RenderThread
- VFXEmitterInfo
- WorldPlace
- StressSceneTests
- Foliage.Curve
- .mark
- normalize
- .bytes

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 493 edges
2. `Scene` - 333 edges
3. `Renderer` - 278 edges
4. `PhysicsWorld` - 272 edges
5. `SIMD4` - 195 edges
6. `Kernel` - 168 edges
7. `Foliage` - 151 edges
8. `simd` - 146 edges
9. `VFXEditorModel` - 122 edges
10. `Benchmark` - 118 edges

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

## Communities (253 total, 17 thin omitted)

### Community 0 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (48): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+40 more)

### Community 3 - "RenderSettings"
Cohesion: 0.07
Nodes (60): Codable, Equatable, Cover, UInt32, UInt64, AgeRule, Ages, CountRule (+52 more)

### Community 4 - "Lights.metal"
Cohesion: 0.08
Nodes (67): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+59 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.08
Nodes (58): half4, float2, float3, float4, primitive_acceleration_structure, read, SCENE_ACCEL, texture2d (+50 more)

### Community 6 - "View"
Cohesion: 0.09
Nodes (40): E, Shape, Binding, .body, CGPoint, CGSize, DragGesture, Float (+32 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "Bool"
Cohesion: 0.06
Nodes (29): Bound, F, .reservoirCount, Bool, .envText, Control, checkbox, custom (+21 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (17): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder, CGRect (+9 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.15
Nodes (14): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, FrameEncoder, RenderAttachments, CompositeInputs, FramePlan, .prev (+6 more)

### Community 14 - "VFXEditorModel"
Cohesion: 0.06
Nodes (33): Phase 2 (the editor window): done, at check-in 2, VFXCatalog, Clip, CGSize, DispatchWorkItem, Float, SceneKind, URL (+25 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.04
Nodes (50): CAMetalLayer, Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue (+42 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (16): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), ParticleCollider, FogVolume, .gpu, LightPose, Kit (+8 more)

### Community 17 - ".part"
Cohesion: 0.19
Nodes (11): simd_quatd, StaticString, T, .layerCount, CharacterImporter, concurrently(), Skeleton, .bindPositions (+3 more)

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
Nodes (75): makeRay(), constant, device, float2, float3, float4, kernel, Light (+67 more)

### Community 22 - ".writeFrameData"
Cohesion: 0.17
Nodes (10): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32, CityLight, Range (+2 more)

### Community 23 - "Int"
Cohesion: 0.05
Nodes (39): MTLRegion, MTLSparseTextureMappingMode, UInt32, LoadStep, MTLResource, Range, Float, UnsafeBufferPointer (+31 more)

### Community 24 - "ParticlesGPU"
Cohesion: 0.11
Nodes (22): Part, Build, Counter, Part, ParticlesGPU, .hasPrograms, .trailShape, MTL4ComputeCommandEncoder (+14 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (60): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+52 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (19): simd_double4x4, GPUJoint, .parent, GPUJointMatrix, Clip, .duration, .loopKeys, Level (+11 more)

### Community 27 - "PlantEditorModel"
Cohesion: 0.05
Nodes (35): AnyObject, Reading the table, ObservableObject, .body, Clip, graft, habitat, leaves (+27 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (149): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+141 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.02
Nodes (83): To do on the M4 Max, Phase 3 (preview tools, backdrops, gizmos): done, at check-in 3, 8. Pipelines and resources, MetalKit, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams (+75 more)

### Community 31 - "String"
Cohesion: 0.07
Nodes (15): MTLBlitCommandEncoder, MTLRenderPassDescriptor, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder, Float, .envText (+7 more)

### Community 32 - "traceKernel"
Cohesion: 0.06
Nodes (77): 3. Occupancy and registers: the default suspect for big kernels, metal_raytracing, metal_stdlib, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0() (+69 more)

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
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUMegaLightsParams, GPUMuscle (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.11
Nodes (16): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, GeneratedCache, Hasher, SectionFile, .array, Data (+8 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "XCTestCase"
Cohesion: 0.05
Nodes (34): Settings: `SettingsTable.swift`, SettingsEnv, EnvVariable, api, denoise, direct, fog, fogSet (+26 more)

### Community 42 - "CaseIterable"
Cohesion: 0.02
Nodes (114): CaseIterable, Tab, ages, boughs, habitat, leaves, look, stems (+106 more)

### Community 43 - "sin"
Cohesion: 0.10
Nodes (11): .front, .forward, meshLights, UnsafeMutableBufferPointer, MeshGeometry, URL, URL, cos (+3 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (36): .empty, RTPart, MTLCommandQueue, MTLDevice, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives (+28 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.14
Nodes (15): Baked, bricks, heights, GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled (+7 more)

### Community 48 - "AppDelegate"
Cohesion: 0.14
Nodes (10): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, Notification, NSWindow, UndoManager (+2 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 51 - "DebugPanel"
Cohesion: 0.08
Nodes (17): NSColor, NSStackView, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, Section (+9 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "SIMD3"
Cohesion: 0.04
Nodes (54): Atmosphere, Float, Int32, GPUParticleField, GPURasterMesh, GPULumenClipLevel, Float, LocalIds (+46 more)

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
Cohesion: 0.06
Nodes (46): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+38 more)

### Community 60 - "SkyParams"
Cohesion: 0.04
Nodes (49): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+41 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.03
Nodes (119): Material, glassKernel(), glassReflection(), constant, device, float3, kernel, read (+111 more)

### Community 62 - "Images"
Cohesion: 0.14
Nodes (4): 6. Math, Modes, Images, SceneKind

### Community 63 - "Types.metal"
Cohesion: 0.06
Nodes (35): InstanceBlockRef, records, MaterialTexture, t, MeshData, block, cutout, firstIndex (+27 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "AABB"
Cohesion: 0.06
Nodes (19): AABB, .area, .centroid, .isEmpty, float4x4, HairStyle, Float, UInt32 (+11 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (20): .instanceAS, .virtualGeometryChanged, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, MTLTexture, UInt32 (+12 more)

### Community 74 - "cross"
Cohesion: 0.06
Nodes (27): Float16, Int8, simd_double3x3, .up, .worldToView, Heightfield, .hi, MeshSDF (+19 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (19): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+11 more)

### Community 77 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 78 - "SDFShape"
Cohesion: 0.09
Nodes (29): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+21 more)

### Community 79 - "FoliageTextures"
Cohesion: 0.06
Nodes (33): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+25 more)

### Community 80 - ".compile"
Cohesion: 0.19
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.12
Nodes (14): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled (+6 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "uint"
Cohesion: 0.12
Nodes (34): candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart() (+26 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.13
Nodes (21): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+13 more)

### Community 86 - "CurveEditor"
Cohesion: 0.05
Nodes (50): L, CurveEditor, .body, .canvas, .points, .presetTitle, EditorGroup, LinearColorPicker (+42 more)

### Community 87 - "Double"
Cohesion: 0.12
Nodes (20): Double, World, .anchorTile, .start, Block, City, Flora, Ground (+12 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.04
Nodes (57): Level, Mesh, Plant, RawRepresentable, Float, Age, mature, sapling (+49 more)

### Community 90 - "GizmoView"
Cohesion: 0.08
Nodes (26): half, gizmoLinesKernel(), GizmoSegment, a, b, color, GizmoView, aspect (+18 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
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
Cohesion: 0.09
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.13
Nodes (8): Cloth, Set, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - ".write"
Cohesion: 0.17
Nodes (17): Card, Skeleton, LeafAnchor, LeafShape, blade, kite, needle, Mesh (+9 more)

### Community 99 - "Footprint"
Cohesion: 0.16
Nodes (13): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .cover (+5 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 102 - "SoftModel"
Cohesion: 0.07
Nodes (29): ArraySlice, GPUPhysicsParticle, GPUSoftVertex, .particleCellSize, Flesh, SIMD2, SkinOptions, SkinShell (+21 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.16
Nodes (11): Building, .triangleCount, BuildingGenerator, Module, SurfaceMaterial, .uvScale, Data, float4x4 (+3 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 107 - "ParticleTests"
Cohesion: 0.14
Nodes (10): GPUParticleRender, Key, ParticleTests, Float, MTLCommandQueue, MTLDevice, StaticString, UInt (+2 more)

### Community 108 - "SkyImage"
Cohesion: 0.12
Nodes (12): Error, LoadError, unreadable, SkyImage, Set, URL, Failure, ShaderSource (+4 more)

### Community 109 - "Benchmark"
Cohesion: 0.09
Nodes (13): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+5 more)

### Community 110 - "VGStreamer"
Cohesion: 0.15
Nodes (10): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, UInt32, VGStreamer, .groupCount (+2 more)

### Community 111 - ".write"
Cohesion: 0.17
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 112 - "Intersect.metal"
Cohesion: 0.18
Nodes (21): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit() (+13 more)

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

### Community 118 - "Config"
Cohesion: 0.11
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 119 - "Scene"
Cohesion: 0.03
Nodes (70): GLTFModel, .bounds, .triangleCount, GPUEmissiveTriangle, Assembly, Bone, BorrowedLight, BorrowedMesh (+62 more)

### Community 120 - "HairTests"
Cohesion: 0.21
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 121 - "Flora"
Cohesion: 0.10
Nodes (14): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+6 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "VFXEffect"
Cohesion: 0.09
Nodes (24): Phase 1 (graph model, code generator, compile, interpreter, ports): done, at check-in 1, UInt32, VFXEffect, VFXEmitter, .parent, .renderer, VFXGradient, .threeKeys (+16 more)

### Community 125 - "PlantTracing"
Cohesion: 0.10
Nodes (22): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+14 more)

### Community 126 - "ParticleSystem"
Cohesion: 0.10
Nodes (15): GPUVFXEmitter, Flags, .gpu, ParticleSystem, .billboardCapacity, .distortRange, .gpuColliders, .gpuEmitters (+7 more)

### Community 127 - "VFXOpKind"
Cohesion: 0.04
Nodes (49): VFXOpKind, abs, add, age, ageOverLife, and, clamp, colorValue (+41 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "FluidSystem"
Cohesion: 0.10
Nodes (19): .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem, .capacity (+11 more)

### Community 130 - ".node"
Cohesion: 0.08
Nodes (30): CustomStringConvertible, Float, Void, VFXCodegen, VFXContext, initialize, output, spawn (+22 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 133 - "Foliage.metal"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "VFXGizmos"
Cohesion: 0.30
Nodes (9): Segment, Float, ParticleEmitter, SIMD2, UInt32, Target, VFXGizmos, View (+1 more)

### Community 135 - "LoadingOverlay"
Cohesion: 0.10
Nodes (16): NSFont, NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item (+8 more)

### Community 136 - "VFXHostingView"
Cohesion: 0.17
Nodes (7): AnyView, NSHostingView, Any, CGPoint, NSEvent, VFXHostingView, .acceptsFirstResponder

### Community 137 - "GPUProfiler"
Cohesion: 0.06
Nodes (29): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+21 more)

### Community 138 - "SIMD4"
Cohesion: 0.07
Nodes (27): GPUPhysicsShape, PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape (+19 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - "VirtualMesh"
Cohesion: 0.16
Nodes (15): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+7 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - ".writeDescriptors"
Cohesion: 0.16
Nodes (8): Float, float3x3, float4x4, UInt32, Wind, PlantTracingTests, MTLCommandQueue, MTLDevice

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
Cohesion: 0.08
Nodes (19): Tests, Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, MTLCommandQueue (+11 more)

### Community 149 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (6): Combine, Element, MetalFX, QuartzCore, Array, Headless

### Community 151 - ".buildStress"
Cohesion: 0.16
Nodes (12): Parts, Hall, Loop, Props, Float, float4x4, SIMD2, Zone (+4 more)

### Community 152 - "Pipelines"
Cohesion: 0.06
Nodes (34): ComputePass, MTLComputePipelineState, Step, Float, FluidGPU, .summary, Steps, MTLBuffer (+26 more)

### Community 153 - "PlantEditorTests"
Cohesion: 0.16
Nodes (6): Host, PlantEditorTests, Root, SceneKind, URL, Void

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Where things are"
Cohesion: 0.13
Nodes (12): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, Habitat, Ramp, Float, SIMD2 (+4 more)

### Community 156 - "RendererController"
Cohesion: 0.09
Nodes (15): .plantStats, RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus, Float, NSEvent (+7 more)

### Community 157 - "CameraTrack"
Cohesion: 0.09
Nodes (15): CameraTrack, .duration, Key, Float, ShowcaseLook, Stage, crypt, forge (+7 more)

### Community 158 - "SDFBox"
Cohesion: 0.10
Nodes (21): device, SDFBox, pad0, pad1, pad2, pad3, scene, shape (+13 more)

### Community 159 - "LayerSurface"
Cohesion: 0.15
Nodes (15): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title (+7 more)

### Community 160 - "TraceScene"
Cohesion: 0.06
Nodes (34): instance_acceleration_structure, RTPart, primitive_acceleration_structure, texture2d_array, uint2, TraceScene, clusterInstance, clusters (+26 more)

### Community 161 - "Camera"
Cohesion: 0.14
Nodes (12): Darwin, SceneKind, Camera, .right, rotate(), Float, float4x4, PlantStats (+4 more)

### Community 162 - "AppKit"
Cohesion: 0.17
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "VFXEditorPanel"
Cohesion: 0.17
Nodes (10): Notification, NSWindow, UndoManager, VFXEditorPanel, .isVisible, .wasVisible, NSWindow, URL (+2 more)

### Community 166 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 167 - ".vgdebug"
Cohesion: 0.12
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

### Community 174 - "SceneBuffersTests"
Cohesion: 0.18
Nodes (7): made, SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 175 - "RasterClusters"
Cohesion: 0.09
Nodes (23): Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer, MTLDevice (+15 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (8): NSWindowDelegate, PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 182 - "float4"
Cohesion: 0.09
Nodes (23): float4, uint4, Particle, info, position, velocity, ParticleEvent, a (+15 more)

### Community 183 - "GLTFError"
Cohesion: 0.24
Nodes (5): GLTFError, .description, URL, CacheTests, URL

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "VoxelGrids"
Cohesion: 0.17
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 186 - "PhysicsWorld"
Cohesion: 0.07
Nodes (31): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+23 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "LumenGlobalSDF"
Cohesion: 0.07
Nodes (31): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+23 more)

### Community 189 - "Key"
Cohesion: 0.24
Nodes (6): Key, PipelineCache, .count, PipelineCacheTests, UInt32, Value

### Community 190 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+15 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

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
Cohesion: 0.14
Nodes (11): Next, The user's choices, Traps found, VFX editor: handoff (branch claude/init-branch-94ae07, PR #54), MTLCommandQueue, MTLDevice, SceneKind, StaticString (+3 more)

### Community 197 - "VFXCompiler"
Cohesion: 0.18
Nodes (15): Hashable, .vfxSetup, Entry, building, failed, ready, Key, ParticleKernels (+7 more)

### Community 198 - "SettingsStore"
Cohesion: 0.22
Nodes (4): base, SettingsStore, Any, DispatchWorkItem

### Community 199 - "VFXParam"
Cohesion: 0.05
Nodes (33): CodingKey, Key, crown, linear, points, taper, Key, whorled (+25 more)

### Community 200 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 201 - "PlantGoldenTests"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 202 - "WorldTile"
Cohesion: 0.10
Nodes (22): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+14 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "VFXBackdrop"
Cohesion: 0.22
Nodes (7): VFXBackdrop, black, dark, grey, night, outdoor, .title

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

### Community 213 - "VFXLayout"
Cohesion: 0.06
Nodes (41): Color, Gesture, Identifiable, Path, CGFloat, .envText, Set, GraphDrags (+33 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 220 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 221 - "RasterScene"
Cohesion: 0.25
Nodes (6): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLDevice, MTLTexture

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "VFXBlockKind"
Cohesion: 0.04
Nodes (51): ParticleTextures.Kind, .name, Float, VFXBlockKind, billboard, burst, collide, color (+43 more)

### Community 224 - "VFXInterpreter"
Cohesion: 0.26
Nodes (9): ParticleEvent, GPUParticle, GPUParticleCollider, GPUParticleEmitter, GPUParticleStep, Float, UInt32, VFXInterpreter (+1 more)

### Community 225 - "float3"
Cohesion: 0.27
Nodes (10): float3, float3x3, float4x4, int3, particleCurl(), particleGradient(), particleMeshTransform(), particleNoise() (+2 more)

### Community 226 - "DebugInfo"
Cohesion: 0.25
Nodes (7): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles

### Community 227 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 228 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 229 - "TraversalStats"
Cohesion: 0.39
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 230 - "GPUMesh"
Cohesion: 0.18
Nodes (5): GPUMesh, UInt64, RasterSceneTests, Float, MeshGeometry

### Community 231 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 232 - "boxCandidate"
Cohesion: 0.48
Nodes (7): boxCandidate(), clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 233 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 234 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 235 - "VGBlas"
Cohesion: 0.29
Nodes (7): VGBlas, attrs, pad0, pad1, pad2, triangles, tris

### Community 236 - "uint"
Cohesion: 0.47
Nodes (10): constant, kernel, uint, vsmAllocKernel(), vsmChunksKernel(), vsmFreeKernel(), vsmResetKernel(), vsmSettleKernel() (+2 more)

### Community 237 - "ParticleStep"
Cohesion: 0.11
Nodes (24): SCENE_ACCEL, thread, particleBasis(), particleBirth(), particleCollide(), ParticleCollider, a, b (+16 more)

### Community 238 - "MuscleSpec"
Cohesion: 0.40
Nodes (5): MuscleSpec, Side, back, front, out

### Community 240 - "particleLightKernel"
Cohesion: 0.11
Nodes (37): Built, Particles: handoff (branch claude/init-branch-94ae07), To do on the M4 Max, Traps found, constant, device, float2, float3 (+29 more)

### Community 243 - "VFXLive.swift"
Cohesion: 0.33
Nodes (4): VFXEditKind, code, rebuild, values

### Community 244 - "Host"
Cohesion: 0.33
Nodes (3): Host, Float, Void

### Community 245 - "Rect"
Cohesion: 0.27
Nodes (5): .area, Float, Rect, .center, .size

### Community 248 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 249 - "ParticleCounts"
Cohesion: 0.15
Nodes (13): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+5 more)

### Community 256 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 257 - "VFXEmitterInfo"
Cohesion: 0.22
Nodes (9): VFXEmitterInfo, attributes, hooks, pad0, pad1, pad2, params, program (+1 more)

### Community 260 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 265 - "Foliage.Curve"
Cohesion: 0.33
Nodes (3): Foliage.Curve, Decoder, Encoder

### Community 277 - "normalize"
Cohesion: 0.13
Nodes (16): OptionSet, Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+8 more)

## Knowledge Gaps
- **1867 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1862 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2523 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **17 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `GLTFLoader`, `RenderSettings`, `View`, `.simplify`, `Bool`, `FramePlan`, `VFXEditorModel`, `Metal4Frame`, `translate`, `.part`, `.writeFrameData`, `ParticlesGPU`, `SkinnedCharacter`, `PlantEditorModel`, `Kernel`, `SettingsPanel`, `Renderer`, `String`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `XCTestCase`, `CaseIterable`, `sin`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `SIMD3`, `MuscleAtlas`, `Images`, `AABB`, `VirtualTracing`, `CityTests`, `cross`, `Metal3Pass`, `VirtualGeometry`, `SDFShape`, `FoliageTextures`, `.compile`, `LoadActivity`, `VirtualBLAS`, `CurveEditor`, `Double`, `Foliage`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `FluidTests`, `PhysicsTests`, `.write`, `Footprint`, `SoftModel`, `Building`, `FBXError`, `ParticleTests`, `SkyImage`, `Benchmark`, `VGStreamer`, `.write`, `BuildingAssembler`, `Config`, `Scene`, `HairTests`, `Flora`, `VFXEffect`, `PlantTracing`, `ParticleSystem`, `FluidSystem`, `.node`, `VFXGizmos`, `LoadingOverlay`, `GPUProfiler`, `SIMD4`, `VoxelLOD`, `VirtualMesh`, `.writeDescriptors`, `CityPlan`, `RagdollTests`, `Slot`, `QuartzCore`, `.buildStress`, `Pipelines`, `Curve`, `RendererController`, `LayerSurface`, `Camera`, `FoliageRuntimeTests`, `VSMTargets`, `SceneBuffersTests`, `RasterClusters`, `GLTFError`, `PhysicsWorld`, `LumenGlobalSDF`, `Key`, `SDFBuffers`, `VFXTests`, `VFXParam`, `WorldTile`, `Terrain`, `VFXLayout`, `RasterScene`, `VFXBlockKind`, `VFXInterpreter`, `DebugInfo`, `TraversalStats`, `GPUMesh`, `Host`, `WorldPlace`, `StressSceneTests`, `normalize`?**
  _High betweenness centrality (0.287) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `GLTFLoader`, `RenderSettings`, `View`, `Bool`, `FramePlan`, `VFXEditorModel`, `Metal4Frame`, `translate`, `.part`, `Int`, `ParticlesGPU`, `SkinnedCharacter`, `PlantEditorModel`, `Kernel`, `SettingsPanel`, `Renderer`, `SectionFile`, `XCTestCase`, `CaseIterable`, `sin`, `SceneBuffers`, `FBXFile`, `DebugPanel`, `SceneKind`, `SIMD3`, `MuscleAtlas`, `Images`, `VirtualTracing`, `VirtualGeometry`, `FoliageTextures`, `.compile`, `LoadActivity`, `VirtualBLAS`, `CurveEditor`, `Capabilities`, `Foliage`, `Upscaler`, `FluidTests`, `.write`, `FBXError`, `ParticleTests`, `SkyImage`, `Benchmark`, `VGStreamer`, `Config`, `Scene`, `Flora`, `VFXEffect`, `ParticleSystem`, `VFXOpKind`, `.node`, `VFXGizmos`, `LoadingOverlay`, `GPUProfiler`, `VirtualMesh`, `CityPlan`, `Map`, `Pipelines`, `PlantEditorTests`, `Curve`, `Where things are`, `RendererController`, `CameraTrack`, `LayerSurface`, `SceneBuffersTests`, `RasterClusters`, `GLTFError`, `VoxelGrids`, `VFXTests`, `VFXCompiler`, `SettingsStore`, `VFXParam`, `PlantGoldenTests`, `WorldTile`, `VFXBackdrop`, `VFXLayout`, `VFXBlockKind`, `DebugInfo`, `TraversalStats`, `MuscleSpec`, `Host`, `.mark`?**
  _High betweenness centrality (0.188) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `Raster.metal`, `device`, `restirGIInitialKernel`, `lumenCardRadiosityKernel`, `Lights.metal`, `flagOn`, `.compile`, `roundToHalf`, `uint`, `pathTraceKernel`, `LightSampling.metal`, `reflectionKernel`, `Renderer`?**
  _High betweenness centrality (0.104) - this node is a cross-community bridge._
- **Are the 55 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 55 INFERRED edges - model-reasoned connections that need verification._
- **Are the 28 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 28 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1867 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `MetalGI Real-Time Ray Tracer` be split into smaller, more focused modules?**
  _Cohesion score 0.0519774011299435 - nodes in this community are weakly interconnected._