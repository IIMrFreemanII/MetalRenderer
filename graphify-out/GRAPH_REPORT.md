# Graph Report - graphify-update-4183f9  (2026-10-07)

## Corpus Check
- 207 files · ~1,194,497 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 4)

## Summary
- 6060 nodes · 18401 edges · 227 communities (212 shown, 15 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2759 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4a949c77`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- AABB
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- FleshFigure
- FBXFile
- .simplify
- Benchmark
- evalcommon.py
- SettingsTable
- NSEvent
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- SIMD3
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- .planFrame
- pathTraceKernel
- .writeFrameData
- TextureStreamer
- GPUMesh
- LightSampling.metal
- SkinnedCharacter
- flagOn
- Kernel
- SettingsPanel
- Renderer
- SettingsTableTests
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
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- FrameEncoder
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- Capabilities
- Types.metal
- Shaders.metal
- VGBlas
- SceneShading
- Direct Rendering Stress Test 32
- .transmittance
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- .grow
- Rect
- Int32
- simd
- Int
- VoxelGrids
- VirtualBLAS
- BVHBuilder
- Pipelines
- ab.sh
- Hair.metal
- CharacterLibrary
- Ray
- MuscleAtlas
- .load
- Double
- VirtualGeometry
- Float
- FoliageTextures
- SurfaceKind
- MuscleTests
- Upscaler
- megaLightsSampleKernel
- .buildStress
- quatRotate
- .length
- lumenTraceKernel
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- BuildingStyle
- EnvVariable
- RendererController
- .build
- instanceRecord
- Species
- .meshes
- WorldTile
- SDFNode
- MetalRenderer
- PhysicsBody
- render.sh
- BuildingAssembler
- LumenSDF.metal
- .buildGallery
- LayerSurface
- Foliage
- same.sh
- .commit
- baseline.sh
- VoxelLOD
- CityPlan
- Primitive
- Raster.metal
- RagdollTests
- .writeDescriptors
- lumenCardRadiosityKernel
- VGStreamer
- pcgHash
- .write
- GLTFModel
- .look
- String
- RenderPass4
- LumenGlobalSDF
- HairTests
- KernelVariantsTests
- RasterClusters.metal
- Post.metal
- SettingsStore
- .draw
- RasterClusters
- VSMCounters
- .capture
- Hit
- Metal
- SDFVolume
- ComputePass
- PlantTracing
- Crown
- What headless changes, and what it doesn't
- Phyllotaxis
- CameraTrack
- .bindScene
- SceneSettings
- TraceScene
- Intersect.metal
- ImageIO
- RasterVGParams
- related.sh
- rotate
- RTVoxels
- Bool
- VGParams
- HairBSDF
- .init
- Shape
- VSM.metal
- RenderView
- RasterScene
- device
- VSMView
- LightMotion
- VSMClusterArgs
- VSMScene
- VirtualTracing
- .stages
- SDFShape
- RasterInstance
- VSMParams
- FoliageVoxels
- uint
- RasterParams
- Slot
- SDFBuffers
- Terrain
- VSMInstance
- Map
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LightKind
- SDFBox
- BVHTests
- RenderThread
- LumenRadiosityParams
- MeshSDF
- Section
- PhysicsGrab
- PhysPush
- LumenParams
- .end
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
- FogNoise.swift
- .testTheCutsBLASHoldsTheCutsTriangles
- .modelURLs
- PhysicsSkinAttach
- PrimitiveWork
- Kind
- Scene
- TraversalStats
- Shape

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 377 edges
2. `Scene` - 282 edges
3. `Renderer` - 253 edges
4. `PhysicsWorld` - 232 edges
5. `.length` - 131 edges
6. `SIMD4` - 130 edges
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

## Communities (227 total, 15 thin omitted)

### Community 0 - "AABB"
Cohesion: 0.08
Nodes (24): AABB, .area, .centroid, .isEmpty, GPUEmissiveTriangle, BorrowedLight, BorrowedMesh, CurveMesh (+16 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.13
Nodes (34): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+26 more)

### Community 3 - "RenderSettings"
Cohesion: 0.20
Nodes (29): Bound, Codable, Equatable, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel (+21 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (78): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+70 more)

### Community 5 - "FleshFigure"
Cohesion: 0.12
Nodes (17): GPUSoftVertex, .cells, Flesh, MuscleSpec, Side, back, front, out (+9 more)

### Community 6 - "FBXFile"
Cohesion: 0.08
Nodes (34): simd_double4x4, simd_quatd, Connection, Contents, FBXError, .description, invalid, unsupported (+26 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Benchmark"
Cohesion: 0.06
Nodes (24): To do on the M4 Max, in order, Render something: `scripts/render.sh`, 6. Math, Modes, Images, Benchmark modes: `Benchmark+Modes.swift`, Benchmark, .framesInConfig (+16 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "SettingsTable"
Cohesion: 0.09
Nodes (26): F, on, Control, checkbox, custom, popup, slider, Custom (+18 more)

### Community 11 - "NSEvent"
Cohesion: 0.15
Nodes (4): InputHandler, Float, NSEvent, SIMD2

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.14
Nodes (28): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+20 more)

### Community 13 - "FramePlan"
Cohesion: 0.21
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+3 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.16
Nodes (12): MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame, MTLCommandBuffer (+4 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.07
Nodes (31): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue, MTL4Compiler, MTL4ComputeCommandEncoder, MTL4UpdateSparseTextureMappingOperation (+23 more)

### Community 16 - "translate"
Cohesion: 0.18
Nodes (15): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+7 more)

### Community 17 - "SIMD3"
Cohesion: 0.06
Nodes (33): GPUHairVertex, GPUPhysicsShape, GPURasterMesh, PhysicsJoint, Float, float4x4, SDFShape, PhysicsCandidate (+25 more)

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.14
Nodes (29): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+21 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - ".planFrame"
Cohesion: 0.08
Nodes (18): MetalKit, GPUPostParams, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets, MegaLightsTargets, PathTracePlan (+10 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (75): makeRay(), constant, device, float2, float3, float4, kernel, Light (+67 more)

### Community 22 - ".writeFrameData"
Cohesion: 0.17
Nodes (9): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32, CityLight, Range (+1 more)

### Community 23 - "TextureStreamer"
Cohesion: 0.08
Nodes (28): MTLRegion, MTLSparseTextureMappingMode, mappings, Entry, Level, SparseMapping, Data, MTLCommandBuffer (+20 more)

### Community 24 - "GPUMesh"
Cohesion: 0.20
Nodes (5): GPUMesh, UInt64, RasterSceneTests, Float, MeshGeometry

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.15
Nodes (13): GPUJoint, .parent, Level, .triangleCount, SkinnedCharacter, .bindPoses, .triangleCount, Float (+5 more)

### Community 27 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (103): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+95 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (56): 8. Pipelines and resources, SkyImage, Set, LoadOptions, PreparedScene, Renderer, .accumulating, .activeDirectMode (+48 more)

### Community 31 - "SettingsTableTests"
Cohesion: 0.08
Nodes (16): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table, Settings: `SettingsTable.swift`, Things that are not structures yet (+8 more)

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (46): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), laineKarrasPermutation(), luminance(), makeSampler(), constant (+38 more)

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
Cohesion: 0.09
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshPin, GPUFogVolume, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUInstanceData (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.11
Nodes (16): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array, Data (+8 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.12
Nodes (19): Card, Plant, Skeleton, LeafAnchor, LeafShape, blade, kite, needle (+11 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.03
Nodes (78): CaseIterable, Backend, auto, gpu, .title, Body, muscles, skin (+70 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

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
Cohesion: 0.16
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (8): NSApplication, NSApplicationDelegate, AppDelegate, Any, Notification, NSWindow, URL, NSWindow

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (17): Crowd, .liveStates, Motion, .isBlend, Part, Slot, State, Float (+9 more)

### Community 50 - "FrameEncoder"
Cohesion: 0.07
Nodes (18): FrameEncoder, Metal3Pass, .declarationScope, PrimitiveRefit, RenderAttachments, AnyObject, MTLAccelerationStructure, MTLBarrierScope (+10 more)

### Community 51 - "DebugPanel"
Cohesion: 0.11
Nodes (12): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, CFTimeInterval, Notification, NSPanel (+4 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (36): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+28 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.10
Nodes (17): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld, .cellSize, .kinematicRows, .params, SIMD2 (+9 more)

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

### Community 59 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 60 - "Types.metal"
Cohesion: 0.06
Nodes (40): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+32 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (109): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+101 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "SceneShading"
Cohesion: 0.07
Nodes (29): MaterialTexture, t, texture2d, texture2d_array, SceneShading, cloudShadow, emissive, feedback (+21 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - ".grow"
Cohesion: 0.17
Nodes (9): float4x4, Baked, bricks, heights, Heightfield, .hi, MeshSDFBuilder, Float (+1 more)

### Community 73 - "Rect"
Cohesion: 0.12
Nodes (17): .area, Float, Block, Lamp, Lot, .front, .size, .transform (+9 more)

### Community 74 - "Int32"
Cohesion: 0.16
Nodes (15): Compression, IteratorProtocol, Sequence, Children, FBXArrayElement, .topLevel, Float, Int32 (+7 more)

### Community 76 - "Int"
Cohesion: 0.06
Nodes (22): OptionSet, Ends, Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState (+14 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (11): MTLResource, BoxData, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32, UInt64 (+3 more)

### Community 78 - "VirtualBLAS"
Cohesion: 0.14
Nodes (21): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+13 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.18
Nodes (11): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+3 more)

### Community 80 - "Pipelines"
Cohesion: 0.18
Nodes (19): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, .function, KernelVariants, .count, Key, Pipelines (+11 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 83 - "CharacterLibrary"
Cohesion: 0.31
Nodes (5): BlobWriter, CharacterLibrary, .directory, Data, URL

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "MuscleAtlas"
Cohesion: 0.07
Nodes (44): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+36 more)

### Community 86 - ".load"
Cohesion: 0.16
Nodes (9): Error, LoadError, unreadable, Failure, ShaderSource, URL, Substring, ShaderSourceTests (+1 more)

### Community 87 - "Double"
Cohesion: 0.10
Nodes (24): Double, Block, City, Flora, Ground, Heavens, .adaptation, .light (+16 more)

### Community 88 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 89 - "Float"
Cohesion: 0.17
Nodes (13): Card, Carve, Graft, Grower, LeafRecipe, Level, Recipe, Skeleton (+5 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.10
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "MuscleTests"
Cohesion: 0.17
Nodes (5): MuscleTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - ".buildStress"
Cohesion: 0.09
Nodes (22): Parts, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Float, float4x4 (+14 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (29): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+21 more)

### Community 99 - "Footprint"
Cohesion: 0.20
Nodes (9): BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops, Float, SIMD2 (+1 more)

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
Cohesion: 0.17
Nodes (10): Hashable, Building, .triangleCount, BuildingGenerator, SurfaceMaterial, .uvScale, float4x4, BuildingTests (+2 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (28): EnvVariable, api, denoise, direct, fog, fogSet, gi, .index (+20 more)

### Community 107 - "RendererController"
Cohesion: 0.12
Nodes (11): AppKit, DebugInfo, Float, RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus (+3 more)

### Community 108 - ".build"
Cohesion: 0.23
Nodes (5): UnsafeBufferPointer, MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 109 - "instanceRecord"
Cohesion: 0.09
Nodes (24): InstanceBlockRef, records, InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1 (+16 more)

### Community 110 - "Species"
Cohesion: 0.10
Nodes (23): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+15 more)

### Community 111 - ".meshes"
Cohesion: 0.13
Nodes (18): .parts, MTLDevice, Cluster, Group, .isRoot, Data, Float, SIMD2 (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.05
Nodes (44): GPUMaterial, Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice (+36 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.41
Nodes (8): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, SplitMix64

### Community 118 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 119 - ".buildGallery"
Cohesion: 0.14
Nodes (3): SplitMix64, UInt64, SDFTests

### Community 120 - "LayerSurface"
Cohesion: 0.13
Nodes (17): AnyObject, CGSize, Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameOutput, Headless, LayerSurface, .backingScale, .isVisible (+9 more)

### Community 121 - "Foliage"
Cohesion: 0.13
Nodes (16): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.25
Nodes (8): FrameTimes, CAMetalDrawable, CFTimeInterval, Void, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 125 - "VoxelLOD"
Cohesion: 0.17
Nodes (13): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLDevice (+5 more)

### Community 126 - "CityPlan"
Cohesion: 0.15
Nodes (12): CityPlan, Edge, open, party, street, Street, View, facade (+4 more)

### Community 127 - "Primitive"
Cohesion: 0.14
Nodes (15): Node, .transform, Op, intersect, subtract, union, Primitive, box (+7 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 130 - ".writeDescriptors"
Cohesion: 0.18
Nodes (9): Tests, float3x3, Float, float4x4, UInt32, Wind, PlantTracingTests, MTLCommandQueue (+1 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.17
Nodes (30): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+22 more)

### Community 132 - "VGStreamer"
Cohesion: 0.14
Nodes (12): Group, Float, MTLBuffer, MTLDevice, Set, SIMD2, UInt32, UnsafePointer (+4 more)

### Community 133 - "pcgHash"
Cohesion: 0.05
Nodes (89): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+81 more)

### Community 134 - ".write"
Cohesion: 0.14
Nodes (11): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+3 more)

### Community 135 - "GLTFModel"
Cohesion: 0.13
Nodes (19): CustomStringConvertible, GLTFError, .description, invalid, unsupported, GLTFModel, .bounds, .triangleCount (+11 more)

### Community 136 - ".look"
Cohesion: 0.26
Nodes (3): URL, URL, ShowcaseTests

### Community 137 - "String"
Cohesion: 0.09
Nodes (13): MTLBlitCommandEncoder, MTLRenderPassDescriptor, Launch, .summary, Frame, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder (+5 more)

### Community 138 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, MTLResource, MTLResourceUsage, UnsafeRawPointer

### Community 139 - "LumenGlobalSDF"
Cohesion: 0.15
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 140 - "HairTests"
Cohesion: 0.16
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 144 - "SettingsStore"
Cohesion: 0.16
Nodes (8): 4. CPU↔GPU data layout, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, What stays fixed, DispatchWorkItem, base, validateGPULayouts(), SettingsStore, Any

### Community 145 - ".draw"
Cohesion: 0.08
Nodes (22): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+14 more)

### Community 146 - "RasterClusters"
Cohesion: 0.11
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "Metal"
Cohesion: 0.19
Nodes (3): Metal, MetalFX, QuartzCore

### Community 151 - "SDFVolume"
Cohesion: 0.17
Nodes (7): Float16, simd_double3x3, SDFVolume, .hi, Float, Float, SDFShape

### Community 152 - "ComputePass"
Cohesion: 0.20
Nodes (10): ComputePass, MTLComputePipelineState, PhysicsGPU, .hasCloth, .hasHair, .hasSoftBodies, PoseParams, MTLBuffer (+2 more)

### Community 153 - "PlantTracing"
Cohesion: 0.15
Nodes (13): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+5 more)

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "What headless changes, and what it doesn't"
Cohesion: 0.40
Nodes (4): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.06
Nodes (23): .current, CameraTrack, .duration, Key, Float, Particles, bubbles, dust (+15 more)

### Community 158 - ".bindScene"
Cohesion: 0.09
Nodes (15): MTLHeap, GPUFogParams, .reflectionPassFlags, GPUSkyParams, MTLComputePipelineState, .instanceAS, .materialBuffers, MTLBuffer (+7 more)

### Community 159 - "SceneSettings"
Cohesion: 0.09
Nodes (12): SceneSettings, SIMD2, ForestTests, GLTFLoaderTests, SceneBuffersTests, Float, MeshGeometry, MTLBuffer (+4 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "ImageIO"
Cohesion: 0.21
Nodes (3): CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "rotate"
Cohesion: 0.20
Nodes (8): Darwin, rotate(), Float, float4x4, RagdollShapes, Float, float4x4, Range

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Bool"
Cohesion: 0.13
Nodes (9): MTL4InstanceAccelerationStructureDescriptor, MTLAccelerationStructureUsage, MTLInstanceAccelerationStructureDescriptor, TLASUpdate, .descriptor, .descriptor4, Bool, .envText (+1 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 170 - ".init"
Cohesion: 0.17
Nodes (9): GPUFleshHeader, PhysicsJointKind, ball, hinge, UInt32, UInt32, Group, MTLDevice (+1 more)

### Community 171 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - "RenderView"
Cohesion: 0.14
Nodes (11): CALayer, CGRect, NSObjectProtocol, NSView, RenderView, .acceptsFirstResponder, MTLDevice, NSCoder (+3 more)

### Community 174 - "RasterScene"
Cohesion: 0.28
Nodes (5): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLTexture

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "VirtualTracing"
Cohesion: 0.14
Nodes (11): .virtualGeometryChanged, MTLResource, MTLAccelerationStructure, MTLBuffer, MTLResource, UInt32, VirtualTracing, .extraInstances (+3 more)

### Community 181 - ".stages"
Cohesion: 0.15
Nodes (13): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 182 - "SDFShape"
Cohesion: 0.28
Nodes (8): SDFShape, .gpuNodes, .materialCount, .stepScale, SurfaceNets, Float, SDFVolume, UInt32

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "FoliageVoxels"
Cohesion: 0.18
Nodes (9): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, FoliageRuntimeTests (+1 more)

### Community 186 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 189 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 190 - "Terrain"
Cohesion: 0.29
Nodes (6): Float, SIMD2, UInt32, UInt64, Terrain, .cell

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "Map"
Cohesion: 0.18
Nodes (9): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, MTLCommandQueue, MTLDevice (+1 more)

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

### Community 197 - "LightKind"
Cohesion: 0.22
Nodes (9): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+1 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "BVHTests"
Cohesion: 0.27
Nodes (5): BVHTests, Float, StaticString, UInt, UInt64

### Community 200 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 201 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 202 - "MeshSDF"
Cohesion: 0.25
Nodes (7): Int8, MeshSDF, .bytes, .hi, .storedBricks, UInt32, .data

### Community 203 - "Section"
Cohesion: 0.25
Nodes (5): NSColor, NSStackView, Section, NSCoder, NSView

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

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

### Community 219 - ".testTheCutsBLASHoldsTheCutsTriangles"
Cohesion: 0.33
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are

### Community 220 - ".modelURLs"
Cohesion: 0.47
Nodes (3): NSDraggingInfo, NSDragOperation, URL

### Community 221 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 222 - "PrimitiveWork"
Cohesion: 0.40
Nodes (3): PrimitiveWork, .encoderCount, MTLAccelerationStructureCommandEncoder

### Community 223 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, arrays, block, clusters, skip, virtual

### Community 224 - "Scene"
Cohesion: 0.06
Nodes (30): SDFVolume, meshLights, Assembly, Bone, Instance, .isGeometry, .isStatic, .moves (+22 more)

### Community 225 - "TraversalStats"
Cohesion: 0.50
Nodes (3): TraversalStats, .description, .rays

### Community 226 - "Shape"
Cohesion: 0.67
Nodes (3): Shape, box, sphere

## Knowledge Gaps
- **1392 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1387 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1904 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **15 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `AABB`, `GLTFLoader`, `RenderSettings`, `FleshFigure`, `FBXFile`, `.simplify`, `Benchmark`, `SettingsTable`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `SIMD3`, `.planFrame`, `.writeFrameData`, `TextureStreamer`, `GPUMesh`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `SettingsTableTests`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FrameEncoder`, `DebugPanel`, `SceneKind`, `PhysicsWorld`, `.transmittance`, `.grow`, `Rect`, `Int32`, `VoxelGrids`, `VirtualBLAS`, `BVHBuilder`, `Pipelines`, `MuscleAtlas`, `Double`, `VirtualGeometry`, `Float`, `FoliageTextures`, `SurfaceKind`, `MuscleTests`, `Upscaler`, `.buildStress`, `.length`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `RendererController`, `.build`, `Species`, `.meshes`, `WorldTile`, `BuildingAssembler`, `.buildGallery`, `LayerSurface`, `Foliage`, `.commit`, `VoxelLOD`, `CityPlan`, `Primitive`, `RagdollTests`, `.writeDescriptors`, `VGStreamer`, `.write`, `GLTFModel`, `String`, `RenderPass4`, `LumenGlobalSDF`, `HairTests`, `.draw`, `RasterClusters`, `SDFVolume`, `ComputePass`, `PlantTracing`, `Phyllotaxis`, `CameraTrack`, `.bindScene`, `SceneSettings`, `rotate`, `Bool`, `.init`, `RasterScene`, `VirtualTracing`, `.stages`, `SDFShape`, `FoliageVoxels`, `Slot`, `SDFBuffers`, `Terrain`, `.addHair`, `LightKind`, `BVHTests`, `MeshSDF`, `PrimitiveWork`, `Scene`, `TraversalStats`?**
  _High betweenness centrality (0.304) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `flagOn`, `Kernel`, `SettingsTableTests`?**
  _High betweenness centrality (0.151) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `Raster.metal`, `restirGIInitialKernel`, `Lights.metal`, `pcgHash`, `instanceRecord`, `device`, `Pipelines`, `Hair.metal`, `Ray`, `pathTraceKernel`, `LightSampling.metal`, `flagOn`, `Shaders.metal`, `Renderer`?**
  _High betweenness centrality (0.139) - this node is a cross-community bridge._
- **Are the 36 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 36 INFERRED edges - model-reasoned connections that need verification._
- **Are the 21 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 21 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1392 weakly-connected nodes found - possible documentation gaps or missing edges._