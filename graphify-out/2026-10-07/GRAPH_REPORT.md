# Graph Report - graphify-update-4183f9  (2026-10-07)

## Corpus Check
- 206 files · ~1,187,777 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 4)

## Summary
- 6033 nodes · 18296 edges · 224 communities (202 shown, 22 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2771 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4a949c77`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- CharacterRig
- out
- .simplify
- Images
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- SIMD3
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- GPUMesh
- LightSampling.metal
- SkinnedCharacter
- geometryDebugKernel
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
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- Capabilities
- FogParams
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
- CityPlan
- Int32
- simd
- Metal3Pass
- VoxelGrids
- VirtualBLAS
- BVHBuilder
- .compile
- ab.sh
- Hair.metal
- FBXError
- Ray
- MuscleAtlas
- .load
- Double
- VirtualGeometry
- Foliage
- FoliageTextures
- SurfaceKind
- MuscleTests
- Map
- megaLightsSampleKernel
- .buildStress
- quatRotate
- .length
- GPULight
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- BuildingStyle
- EnvVariable
- SceneData
- .build
- MeshData
- Species
- .build
- WorldTile
- SDFNode
- MetalRenderer
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- .buildGallery
- Config
- Flora
- same.sh
- .commit
- baseline.sh
- VoxelLOD
- CityTests
- SDFShape
- Raster.metal
- RagdollTests
- .writeDescriptors
- lumenCardRadiosityKernel
- Int
- PlantWind
- .write
- .meshes
- Benchmark
- Frame
- RenderPass4
- LumenGlobalSDF
- HairTests
- KernelVariantsTests
- RasterClusters.metal
- SkyParams
- SettingsStore
- Measuring MetalRenderer
- .gpuCut
- VSMCounters
- .capture
- Hit
- Metal
- SDFVolume
- Pipelines
- PlantTracing
- Crown
- .env
- Phyllotaxis
- CameraTrack
- VirtualTracing
- Stored
- TraceScene
- Intersect.metal
- ImageIO
- RasterVGParams
- related.sh
- Camera
- RTVoxels
- .addFleshCharacter
- VGParams
- HairBSDF
- Float
- Shape
- VSM.metal
- StressSceneTests
- RasterScene
- device
- VSMView
- LightMotion
- VSMClusterArgs
- VSMScene
- PostParams
- .init
- PlantTracingTests
- RasterInstance
- VSMParams
- FoliageVoxels
- uint
- RasterParams
- XCTestCase
- SDFBuffers
- float4
- VSMInstance
- KernelVariants
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LightKind
- SDFBox
- Types.metal
- Stage
- TextureStreamerTests
- .origin
- .roof
- PhysicsGrab
- PhysPush
- Particles
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
- .setTexture
- .setComputePipelineState
- PhysicsSkinAttach
- .useResource
- AABB

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 361 edges
2. `Scene` - 282 edges
3. `Renderer` - 253 edges
4. `PhysicsWorld` - 232 edges
5. `.length` - 130 edges
6. `SIMD4` - 130 edges
7. `Kernel` - 120 edges
8. `Benchmark` - 108 edges
9. `simd` - 104 edges
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

## Communities (224 total, 22 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.06
Nodes (26): GPUEmissiveTriangle, meshLights, .viewNote, BorrowedLight, CityLight, CurveMesh, MeshLight, MeshLightDraft (+18 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (47): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+39 more)

### Community 3 - "RenderSettings"
Cohesion: 0.11
Nodes (33): Codable, Equatable, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel, FogSettings (+25 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (78): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+70 more)

### Community 5 - "CharacterRig"
Cohesion: 0.10
Nodes (23): GPUSoftVertex, .cells, Axis, along, front, up, Flesh, MuscleSpec (+15 more)

### Community 6 - "out"
Cohesion: 0.16
Nodes (15): simd_double4x4, simd_quatd, StaticString, Side, back, front, out, CharacterImporter (+7 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Images"
Cohesion: 0.21
Nodes (3): 6. Math, Modes, Images

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "Bool"
Cohesion: 0.06
Nodes (31): Bound, F, .reservoirCount, Bool, .envText, Control, checkbox, custom (+23 more)

### Community 11 - "RenderView"
Cohesion: 0.05
Nodes (32): AnyObject, CALayer, CGRect, CGSize, NSDraggingInfo, NSDragOperation, NSObjectProtocol, NSView (+24 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.15
Nodes (15): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, ComputeStage, FrameEncoder, RenderAttachments, CompositeInputs, FramePlan (+7 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.09
Nodes (18): MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame, PrimitiveWork (+10 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.08
Nodes (25): MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandBuffer, MTL4CommandQueue, MTL4Compiler, MTL4ComputeCommandEncoder, MTL4UpdateSparseTextureMappingOperation, MTLAllocation (+17 more)

### Community 16 - "translate"
Cohesion: 0.18
Nodes (15): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, float4x4, LightPose, Kit (+7 more)

### Community 17 - "SIMD3"
Cohesion: 0.07
Nodes (29): GPUHairVertex, GPUPhysicsShape, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind (+21 more)

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.14
Nodes (29): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+21 more)

### Community 19 - "Fog.metal"
Cohesion: 0.13
Nodes (47): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+39 more)

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
Cohesion: 0.11
Nodes (19): MTLRegion, MTLSparseTextureMappingMode, SparseMapping, MTLBuffer, MTLCommandBuffer, MTLHeap, MTLPixelFormat, MTLSize (+11 more)

### Community 24 - "GPUMesh"
Cohesion: 0.15
Nodes (6): GPUMesh, UInt64, MTLDevice, RasterSceneTests, Float, MeshGeometry

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (49): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), giLightIllum(), lastFramePixel(), LightCandidate, element, uv (+41 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.14
Nodes (15): GPUJoint, Clip, .duration, .loopKeys, Level, .triangleCount, SkinnedCharacter, .bindPoses (+7 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.12
Nodes (45): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+37 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (103): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+95 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (76): 8. Pipelines and resources, MetalKit, SkyImage, Set, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams (+68 more)

### Community 31 - "SettingsTableTests"
Cohesion: 0.11
Nodes (10): Settings: `SettingsTable.swift`, Things that are not structures yet, Where new code belongs, SkyMode, atmosphere, constant, image, .title (+2 more)

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (48): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, penumbraWidth(), cosineSampleHemisphere(), laineKarrasPermutation(), luminance(), makeSampler() (+40 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (32): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+24 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

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
Cohesion: 0.10
Nodes (17): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array (+9 more)

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
Cohesion: 0.03
Nodes (78): CaseIterable, NSColor, NSStackView, Section, NSCoder, Backend, auto, gpu (+70 more)

### Community 43 - "VSMTargets"
Cohesion: 0.14
Nodes (15): GPUVSMView, Light, .views, Float, MTLBuffer, MTLDevice, MTLResource, MTLTexture (+7 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (33): .empty, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction, unsupported (+25 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.11
Nodes (27): quantizeUV(), constant, device, float2, float3, float4, kernel, thread (+19 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.11
Nodes (11): NSApplication, NSApplicationDelegate, AppDelegate, Any, Notification, NSWindow, URL, RenderThread (+3 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 51 - "RendererController"
Cohesion: 0.05
Nodes (30): NSRect, NSWindowDelegate, DebugInfo, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView (+22 more)

### Community 52 - "SceneKind"
Cohesion: 0.06
Nodes (36): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+28 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.09
Nodes (19): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld, .cellSize, .kinematicRows, .params, Range (+11 more)

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

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.04
Nodes (78): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+70 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

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
Cohesion: 0.11
Nodes (15): Int8, float4x4, Baked, bricks, heights, Heightfield, .hi, MeshSDF (+7 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "Int32"
Cohesion: 0.41
Nodes (6): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 76 - "Metal3Pass"
Cohesion: 0.05
Nodes (26): MTL4InstanceAccelerationStructureDescriptor, Metal3Pass, .declarationScope, Metal3RenderPass, PrimitiveRefit, RenderPass, AnyObject, MTLAccelerationStructure (+18 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.16
Nodes (11): MTLResource, BoxData, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32, UInt64 (+3 more)

### Community 78 - "VirtualBLAS"
Cohesion: 0.13
Nodes (22): Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+14 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - ".compile"
Cohesion: 0.31
Nodes (9): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, .function, AnyObject, MTLDevice, MTLPixelFormat, MTLRenderPipelineState (+1 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 83 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "MuscleAtlas"
Cohesion: 0.10
Nodes (29): .parent, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, on (+21 more)

### Community 86 - ".load"
Cohesion: 0.12
Nodes (13): CustomStringConvertible, Error, LoadError, unreadable, GLTFError, .description, .data, Failure (+5 more)

### Community 87 - "Double"
Cohesion: 0.05
Nodes (43): Launch, .summary, Double, Float, SIMD2, World, World, .anchorTile (+35 more)

### Community 88 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 89 - "Foliage"
Cohesion: 0.18
Nodes (15): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+7 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.10
Nodes (23): Hashable, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness (+15 more)

### Community 92 - "MuscleTests"
Cohesion: 0.12
Nodes (10): GPUFleshHeader, UInt32, Group, MTLDevice, UInt32, MuscleTests, Float, MTLCommandQueue (+2 more)

### Community 93 - "Map"
Cohesion: 0.11
Nodes (17): Map, Float, SIMD2, UpscaleInputs, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture (+9 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - ".buildStress"
Cohesion: 0.09
Nodes (25): OptionSet, Parts, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+17 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "GPULight"
Cohesion: 0.17
Nodes (12): GPULight, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2, UInt32 (+4 more)

### Community 99 - "Footprint"
Cohesion: 0.19
Nodes (9): BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops, Float, SIMD2 (+1 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (20): ArraySlice, simd_float3x3, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius (+12 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.09
Nodes (22): Building, BuildingGenerator, Slot, accent, blind, dark, floor, frame (+14 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 107 - "SceneData"
Cohesion: 0.08
Nodes (25): texture2d, texture2d_array, uint4, SceneData, cloudShadow, emissive, feedback, indices (+17 more)

### Community 108 - ".build"
Cohesion: 0.23
Nodes (5): UnsafeBufferPointer, MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 110 - "Species"
Cohesion: 0.09
Nodes (23): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+15 more)

### Community 111 - ".build"
Cohesion: 0.16
Nodes (13): Cluster, Group, .isRoot, Float, SIMD2, UInt32, UInt64, UInt8 (+5 more)

### Community 112 - "WorldTile"
Cohesion: 0.09
Nodes (25): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+17 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.41
Nodes (8): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, SplitMix64

### Community 118 - "lumenTraceKernel"
Cohesion: 0.05
Nodes (89): int4, distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams (+81 more)

### Community 120 - "Config"
Cohesion: 0.15
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 121 - "Flora"
Cohesion: 0.10
Nodes (15): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.23
Nodes (9): CAMetalLayer, FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, MTLCommandQueue, MTLDevice (+1 more)

### Community 125 - "VoxelLOD"
Cohesion: 0.17
Nodes (13): Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 127 - "SDFShape"
Cohesion: 0.08
Nodes (34): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+26 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "RagdollTests"
Cohesion: 0.16
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 130 - ".writeDescriptors"
Cohesion: 0.27
Nodes (6): Tests, float3x3, Float, float4x4, UInt32, Wind

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (49): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+41 more)

### Community 132 - "Int"
Cohesion: 0.04
Nodes (56): GPUSkyParams, Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState (+48 more)

### Community 133 - "PlantWind"
Cohesion: 0.07
Nodes (50): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are, boneAngle(), bucketPhase(), coverLean(), meanGust() (+42 more)

### Community 134 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 135 - ".meshes"
Cohesion: 0.18
Nodes (4): GLTFModel, .bounds, .triangleCount, URL

### Community 136 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - "Frame"
Cohesion: 0.19
Nodes (7): MTLBlitCommandEncoder, MTLRenderPassDescriptor, Frame, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder

### Community 138 - "RenderPass4"
Cohesion: 0.14
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 139 - "LumenGlobalSDF"
Cohesion: 0.15
Nodes (10): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+2 more)

### Community 140 - "HairTests"
Cohesion: 0.21
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 141 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 144 - "SettingsStore"
Cohesion: 0.10
Nodes (16): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, The pass, The pass after a feature (+8 more)

### Community 145 - "Measuring MetalRenderer"
Cohesion: 0.12
Nodes (11): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table, Proving a refactor changed nothing, Scorers and other tools (+3 more)

### Community 146 - ".gpuCut"
Cohesion: 0.27
Nodes (9): Result, GPUCut, Error, float4x4, MTLComputePipelineState, MTLDevice, Set, UInt32 (+1 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "Metal"
Cohesion: 0.12
Nodes (4): Metal, MetalFX, QuartzCore, Headless

### Community 151 - "SDFVolume"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

### Community 152 - "Pipelines"
Cohesion: 0.14
Nodes (17): ComputePass, MTLResource, MTLResourceUsage, MTLComputePipelineState, PhysicsGPU, .hasCloth, .hasHair, .hasSoftBodies (+9 more)

### Community 153 - "PlantTracing"
Cohesion: 0.17
Nodes (13): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+5 more)

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - ".env"
Cohesion: 0.14
Nodes (6): To do on the M4 Max, in order, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.13
Nodes (7): CameraTrack, .duration, Key, Float, ShowcaseLook, Float, Void

### Community 158 - "VirtualTracing"
Cohesion: 0.08
Nodes (22): MTLComputePipelineState, .virtualGeometryChanged, Content, Float, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32 (+14 more)

### Community 159 - "Stored"
Cohesion: 0.10
Nodes (15): Instance, .isGeometry, .isStatic, .moves, InstanceGroup, Stored, .count, made (+7 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "ImageIO"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "Camera"
Cohesion: 0.17
Nodes (12): Darwin, Camera, .forward, .right, .up, .worldToView, rotate(), Float (+4 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - ".addFleshCharacter"
Cohesion: 0.23
Nodes (5): Float, float4x4, SDFShape, RagdollShapes, SDFShape

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 170 - "Float"
Cohesion: 0.17
Nodes (8): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, UInt32

### Community 171 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 174 - "RasterScene"
Cohesion: 0.29
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

### Community 180 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 181 - ".init"
Cohesion: 0.32
Nodes (6): Entry, Level, Data, MTLCommandQueue, MTLDevice, URL

### Community 182 - "PlantTracingTests"
Cohesion: 0.36
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 185 - "FoliageVoxels"
Cohesion: 0.20
Nodes (9): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, FoliageRuntimeTests (+1 more)

### Community 186 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "XCTestCase"
Cohesion: 0.20
Nodes (5): CacheTests, URL, GLTFLoaderTests, VGStreamerTests, XCTestCase

### Community 189 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 190 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "KernelVariants"
Cohesion: 0.38
Nodes (6): KernelVariants, .count, Key, MTLComputePipelineState, Set, UInt32

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

### Community 199 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 200 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 201 - "TextureStreamerTests"
Cohesion: 0.29
Nodes (3): .residentLevels, URL, TextureStreamerTests

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

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

### Community 221 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 224 - "AABB"
Cohesion: 0.09
Nodes (20): AABB, .area, .centroid, .isEmpty, SDFVolume, Assembly, Bone, BorrowedMesh (+12 more)

## Knowledge Gaps
- **1393 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1388 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1903 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **22 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `CharacterRig`, `out`, `.simplify`, `Images`, `Bool`, `RenderView`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `SIMD3`, `LightTable`, `TextureStreamer`, `GPUMesh`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `SettingsTableTests`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `Mesh`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `Crowd`, `FBXFile`, `RendererController`, `SceneKind`, `PhysicsWorld`, `.transmittance`, `.grow`, `CityPlan`, `Int32`, `Metal3Pass`, `VoxelGrids`, `VirtualBLAS`, `BVHBuilder`, `FBXError`, `MuscleAtlas`, `Double`, `VirtualGeometry`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `MuscleTests`, `Map`, `.buildStress`, `.length`, `GPULight`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `.build`, `Species`, `.build`, `WorldTile`, `BuildingAssembler`, `.buildGallery`, `Config`, `Flora`, `.commit`, `VoxelLOD`, `CityTests`, `SDFShape`, `RagdollTests`, `.writeDescriptors`, `.write`, `.meshes`, `Benchmark`, `Frame`, `RenderPass4`, `LumenGlobalSDF`, `HairTests`, `.gpuCut`, `SDFVolume`, `Pipelines`, `PlantTracing`, `Phyllotaxis`, `VirtualTracing`, `Stored`, `Camera`, `.addFleshCharacter`, `Float`, `StressSceneTests`, `RasterScene`, `.init`, `PlantTracingTests`, `FoliageVoxels`, `SDFBuffers`, `KernelVariants`, `.addHair`, `LightKind`, `TextureStreamerTests`, `.origin`, `.roof`, `.setTexture`, `AABB`?**
  _High betweenness centrality (0.317) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `.compile` to `KernelVariants`, `restirTemporalKernel`, `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `Pipelines`, `Kernel`, `SettingsTableTests`?**
  _High betweenness centrality (0.161) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `Raster.metal`, `restirTemporalKernel`, `restirGIInitialKernel`, `Lights.metal`, `device`, `.compile`, `Hair.metal`, `Fog.metal`, `Ray`, `pathTraceKernel`, `lumenTraceKernel`, `LightSampling.metal`, `Shaders.metal`, `Renderer`?**
  _High betweenness centrality (0.134) - this node is a cross-community bridge._
- **Are the 35 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 35 INFERRED edges - model-reasoned connections that need verification._
- **Are the 21 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 21 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1393 weakly-connected nodes found - possible documentation gaps or missing edges._