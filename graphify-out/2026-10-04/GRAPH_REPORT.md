# Graph Report - MetalGI  (2026-10-04)

## Corpus Check
- 139 files · ~1,025,706 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 21 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 3)

## Summary
- 3761 nodes · 10681 edges · 179 communities (164 shown, 15 thin omitted)
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 1497 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `5d2debe3`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Equatable
- Lights.metal
- Frame
- FBXFile
- .simplify
- Benchmark
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- .drawFrame
- GPUProfiler
- Metal4Frame
- .addLight
- .meshes
- atrousKernel
- Fog.metal
- Sky.metal
- MTKView
- LightTable
- TextureStreamer
- Int
- LightSampling.metal
- SIMD4
- Output.metal
- Kernel
- SettingsPanel
- Renderer
- SceneSettings
- traceKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- BVHBuild.metal
- Uniforms
- Mesh
- RenderAPI
- Direct Lighting Reference Scene
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- Geometric Test Primitives
- AppDelegate
- Crowd
- .int
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- RTScene
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- Capabilities
- FogParams
- reflectionKernel
- RTVoxels
- SceneShading
- Direct Rendering Stress Test 32
- SkyImage
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- CustomRayTracer
- Rect
- Int32
- simd
- Metal3Pass
- FoliageVoxels
- VirtualBLAS
- .buildBLAS
- Pipelines
- ab.sh
- ShadingPoint
- FBXError
- Intersect.metal
- EmissiveTriangle
- .load
- World
- .build
- Foliage
- FoliageTextures
- SurfaceKind
- SkyParams
- Upscaler
- crowdPoseKernel
- MeshBuilder
- PoseSlot
- GLTFModel
- SceneData
- Footprint
- Crowd.metal
- RTBlockInstance
- .write
- Camera
- Building
- BuildingStyle
- .commit
- Types.metal
- Material
- MeshData
- Species
- WorldTests
- WorldTile
- CrowdPoseParams
- MetalRenderer
- CrowdSkinParams
- render.sh
- BuildingAssembler
- CPU (Swift) practices for MetalRenderer
- Config
- WorldPlace
- Flora
- same.sh
- .commit
- baseline.sh
- VoxelLOD
- CityPlan
- CrowdRefitParams
- SkinVertex
- CrowdJoint
- AppKit
- DebugInfo
- .instances
- PlantWind
- Terrain
- VirtualGeometry.metal
- BenchmarkModesTests
- MTLTexture
- .useResource
- FrameEncoder
- RTPart
- Map
- FoliageRuntimeTests
- LightKind
- SettingsStore
- CharacterImporter
- BVHTests
- GPU (Metal / MSL) practices for MetalRenderer
- .capture
- Hit
- Metal
- SplitMix64
- .encode
- SceneBuffersTests
- Crown
- Measuring MetalRenderer
- Phyllotaxis
- AABB
- VGInstance
- RTInstance
- Modes
- VGParams
- ImageIO
- .init
- related.sh
- .setComputePipelineState
- Contents
- Custom
- VGCluster
- TextureStreamerTests
- XCTestCase
- Shape
- .bind
- RendererError
- VGBlas
- Builder
- Part
- LightMotion
- .runTest

## God Nodes (most connected - your core abstractions)
1. `Renderer` - 199 edges
2. `Scene` - 172 edges
3. `SIMD3` - 162 edges
4. `Foliage` - 88 edges
5. `RenderSettings` - 84 edges
6. `Benchmark` - 83 edges
7. `Kernel` - 74 edges
8. `Config` - 66 edges
9. `Metal4Frame` - 58 edges
10. `World` - 57 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Direct Lighting Scene Components** — tools_eval_refs_upscale_ref_direct_light_source, tools_eval_refs_upscale_ref_direct_geometric_primitives, tools_eval_refs_upscale_ref_direct_material_properties, tools_eval_refs_upscale_ref_direct_shadow_rendering [EXTRACTED 0.95]
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
- **Reference Test Geometry Set** — tools_eval_refs_upscale_ref_albedo_red_cube, tools_eval_refs_upscale_ref_albedo_blue_arc, tools_eval_refs_upscale_ref_albedo_green_cube, tools_eval_refs_upscale_ref_albedo_yellow_polygon, tools_eval_refs_upscale_ref_albedo_black_sphere [INFERRED 0.85]
- **Stress Test Rendering Methodology** — geometric_primitives_rendering_test, object_density_distribution, color_variation_visual_clarity [INFERRED 0.85]
- **Stress Test Rendering Pipeline** — tools_eval_refs_stress_ref_direct_32_direct_rendering, tools_eval_refs_stress_ref_direct_32_3d_objects, tools_eval_refs_stress_ref_direct_32_lighting [INFERRED 0.85]
- **Global Illumination Rendering Components** — tools_eval_refs_gi_ref8_0_5x_geometric_primitives, tools_eval_refs_gi_ref8_0_5x_material_surfaces, tools_eval_refs_gi_ref8_0_5x_light_source [INFERRED 0.85]

## Communities (179 total, 15 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.07
Nodes (42): GPUEmissiveTriangle, .windFrame, Assembly, Bone, BorrowedLight, BorrowedMesh, BorrowedTree, Instance (+34 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.17
Nodes (31): Buffer, Decodable, Decoder, Node, Accessor, AnyDecodable, Asset, Buffer (+23 more)

### Community 3 - "Equatable"
Cohesion: 0.21
Nodes (21): Bound, Codable, Equatable, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel (+13 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (67): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+59 more)

### Community 5 - "Frame"
Cohesion: 0.15
Nodes (8): MTLBlitCommandEncoder, MTLCommandEncoder, Frame, Optional, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, String

### Community 6 - "FBXFile"
Cohesion: 0.18
Nodes (12): IteratorProtocol, Sequence, Children, Connection, FBXFile, .topLevel, Node, StaticString (+4 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Benchmark"
Cohesion: 0.10
Nodes (11): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+3 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "Bool"
Cohesion: 0.11
Nodes (24): F, .outputs, RenderSettings, Bool, .envText, CGFloat, .envText, Control (+16 more)

### Community 11 - "RenderView"
Cohesion: 0.15
Nodes (10): NSDraggingInfo, NSDragOperation, InputHandler, RenderView, .acceptsFirstResponder, Float, NSEvent, URL (+2 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, RC_MAX_CASCADES, makeRay(), constant, device, float3, float4, kernel (+21 more)

### Community 13 - ".drawFrame"
Cohesion: 0.19
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputePass, ComputeStage, MTLComputePipelineState, CompositeInputs, FramePlan, .prev (+3 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.16
Nodes (12): MTLCounterSampleBuffer, MTLCounterSet, MTLTimestamp, Metal3Frame, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLCommandQueue, String (+4 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.07
Nodes (32): MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTL4ComputeCommandEncoder, MTL4UpdateSparseTextureMappingOperation, MTLAllocation, MTLResidencySet (+24 more)

### Community 16 - ".addLight"
Cohesion: 0.22
Nodes (10): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, LightPose, Kit, Float, String (+2 more)

### Community 17 - ".meshes"
Cohesion: 0.17
Nodes (16): Cluster, Group, .isRoot, Data, Float, SIMD2, String, UInt32 (+8 more)

### Community 18 - "atrousKernel"
Cohesion: 0.29
Nodes (18): atrousKernel(), depthGradient(), geometryWeights(), constant, float2, float3, float4, int2 (+10 more)

### Community 19 - "Fog.metal"
Cohesion: 0.15
Nodes (43): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+35 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (41): level, atmosphereExtinction(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+33 more)

### Community 21 - "MTKView"
Cohesion: 0.11
Nodes (19): AnyObject, Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, Things that are not structures yet, Where new code belongs, CGSize, FrameOutput, Headless, MTKView (+11 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.11
Nodes (24): MTLRegion, MTLSparseTextureMappingMode, .data, Entry, Level, SparseMapping, Data, MTLBuffer (+16 more)

### Community 24 - "Int"
Cohesion: 0.11
Nodes (21): Int, .envText, MTLDevice, UInt64, TileAllocator, BuddyAllocator, Group, Params (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (49): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+41 more)

### Community 26 - "SIMD4"
Cohesion: 0.12
Nodes (18): simd_double4x4, simd_quatf, .worldToView, Clip, .duration, .loopKeys, Level, .triangleCount (+10 more)

### Community 27 - "Output.metal"
Cohesion: 0.15
Nodes (35): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), clipToBox(), compositeKernel(), debugHashColor(), debugHeat() (+27 more)

### Community 28 - "Kernel"
Cohesion: 0.04
Nodes (57): Kernel, accumulate, accumulateColor, atrous, cloudNoise, cloudShadow, composite, crowdPose (+49 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.11
Nodes (19): NSControl, NSGridView, NSObject, NSSize, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (53): 8. Pipelines and resources, MTKViewDelegate, FrameSize, .upscaling, LoadOptions, PreparedScene, Renderer, .activeDirectMode (+45 more)

### Community 31 - "SceneSettings"
Cohesion: 0.06
Nodes (30): Settings: `SettingsTable.swift`, SceneSettings, SIMD2, SettingsEnv, String, EnvVariable, api, denoise (+22 more)

### Community 32 - "traceKernel"
Cohesion: 0.10
Nodes (42): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), luminance(), makeSampler(), float2, float3 (+34 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.12
Nodes (21): simd_float4x4, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUInstanceData, GPUJoint, .parent, GPUJointMatrix (+13 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (19): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, Section, Section, GeneratedCache, Hasher, SectionFile (+11 more)

### Community 39 - "BVHBuild.metal"
Cohesion: 0.19
Nodes (23): 5. Reductions, atomics and threadgroup memory, boxToWorld(), KarrasRange, first, last, split, coherent, constant (+15 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.13
Nodes (18): Plant, Skeleton, LeafShape, blade, kite, needle, Mesh, .leafTriangles (+10 more)

### Community 42 - "RenderAPI"
Cohesion: 0.05
Nodes (55): CaseIterable, Age, mature, sapling, young, DirectLightMode, auto, exact (+47 more)

### Community 43 - "Direct Lighting Reference Scene"
Cohesion: 0.20
Nodes (10): Colored Environment Walls, Cube Object, Direct Lighting Reference Scene, Geometric Primitives, Point Light Source, Material Properties, Rectangular Prism Object, Rendering Quality Evaluation Reference (+2 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.09
Nodes (30): .instanceDescriptorStride, InstanceBlock, .hasTree, .held, .records, MeshBlock, .hasBorrowedTree, .hasTree (+22 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.11
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "Geometric Test Primitives"
Cohesion: 0.22
Nodes (9): Albedo Reference Test Image, Albedo Material Property Testing, Black Reference Sphere, Blue Arc Surface, Geometric Test Primitives, Green Cube (Matte Surface), Red Cube (Matte Surface), Upscaling Algorithm Evaluation (+1 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (8): NSApplication, NSApplicationDelegate, AppDelegate, Any, Notification, NSWindow, URL, NSWindow

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - ".int"
Cohesion: 0.38
Nodes (4): invalid, String, T, UnsafeRawBufferPointer

### Community 51 - "DebugPanel"
Cohesion: 0.10
Nodes (14): NSRect, NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval (+6 more)

### Community 52 - "SceneKind"
Cohesion: 0.07
Nodes (29): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+21 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "RTScene"
Cohesion: 0.09
Nodes (22): RTScene, blas, clusters, cutouts, dynamicRoot, instances, nodeInstance, pad (+14 more)

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
Cohesion: 0.28
Nodes (7): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, String, CapabilitiesTests, .none, Void

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.04
Nodes (98): Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), metal_raytracing, metal_stdlib, RTPart, glassKernel(), glassReflection(), constant, device (+90 more)

### Community 62 - "RTVoxels"
Cohesion: 0.12
Nodes (17): device, uint4, RTVoxels, dims, lo, offsets, VGClusterView, nodes (+9 more)

### Community 63 - "SceneShading"
Cohesion: 0.17
Nodes (12): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+4 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "SkyImage"
Cohesion: 0.31
Nodes (7): Atmosphere, LoadError, unreadable, SkyImage, Float, Set, String

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "CustomRayTracer"
Cohesion: 0.07
Nodes (31): CustomRayTracer, .buffers, .dynamicNodeBase, .dynamicRoot, .virtualNodeBase, LBVHCounts, buffer, bytes (+23 more)

### Community 73 - "Rect"
Cohesion: 0.09
Nodes (22): OptionSet, .area, Ends, Float, Block, Lamp, Rect, .center (+14 more)

### Community 74 - "Int32"
Cohesion: 0.26
Nodes (10): Compression, FBXArrayElement, Float, Int32, Int64, LocalIds, MeshClusterizer, Float (+2 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.12
Nodes (10): Metal3Pass, .declarationScope, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, MTLHeap, MTLSize, MTLTexture (+2 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.14
Nodes (19): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, String, UInt32 (+11 more)

### Community 78 - "VirtualBLAS"
Cohesion: 0.16
Nodes (16): CutInput, Entry, Float, float4x4, MTLBuffer, MTLDevice, MTLResource, Range (+8 more)

### Community 79 - ".buildBLAS"
Cohesion: 0.19
Nodes (12): BLASResult, BVHBuilder, BVHNode, Node, Float, SIMD2, String, UInt32 (+4 more)

### Community 80 - "Pipelines"
Cohesion: 0.25
Nodes (14): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, KernelVariants, .count, Key, Pipelines, .rc (+6 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "ShadingPoint"
Cohesion: 0.22
Nodes (9): ShadingPoint, albedo, f0, n, ng, p, roughness, specular (+1 more)

### Community 83 - "FBXError"
Cohesion: 0.19
Nodes (10): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Data, StaticString (+2 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.19
Nodes (26): intersection_params, intersectAny(), intersectClosest(), intersectClosestCost(), intersectDistance(), constant, float3, SCENE_ACCEL (+18 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.19
Nodes (8): Failure, ShaderSource, String, URL, Substring, ShaderSourceTests, String, URL

### Community 87 - "World"
Cohesion: 0.16
Nodes (17): Float, Double, .anchorTile, .start, Block, City, Flora, Ground (+9 more)

### Community 88 - ".build"
Cohesion: 0.22
Nodes (8): GPUMaterial, Assembler, Draft, Data, float4x4, SIMD2, UInt8, Void

### Community 89 - "Foliage"
Cohesion: 0.19
Nodes (15): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+7 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (18): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+10 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.10
Nodes (22): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+14 more)

### Community 92 - "SkyParams"
Cohesion: 0.18
Nodes (11): SkyParams, cloudLayer, cloudShape, flags, ground, place, shadowMap, sun (+3 more)

### Community 93 - "Upscaler"
Cohesion: 0.10
Nodes (20): MTLFXSpatialScaler, MTLFXTemporalDenoisedScalerBase, MTLFXTemporalScaler, Float, SIMD2, UpscaleInputs, AnyObject, Float (+12 more)

### Community 94 - "crowdPoseKernel"
Cohesion: 0.31
Nodes (11): crowdLeaf(), crowdPoseKernel(), crowdRefitKernel(), crowdSkinKernel(), coherent, constant, device, kernel (+3 more)

### Community 95 - "MeshBuilder"
Cohesion: 0.18
Nodes (11): Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Float, float4x4 (+3 more)

### Community 96 - "PoseSlot"
Cohesion: 0.18
Nodes (11): crowdRoot(), float3, PoseSlot, blend, pad, rootA, rootB, rotationsA (+3 more)

### Community 97 - "GLTFModel"
Cohesion: 0.11
Nodes (22): CustomStringConvertible, Error, GLTFError, .description, invalid, unsupported, GLTFModel, .triangleCount (+14 more)

### Community 98 - "SceneData"
Cohesion: 0.08
Nodes (26): device, texture2d, texture2d_array, uint4, SceneData, cloudShadow, emissive, feedback (+18 more)

### Community 99 - "Footprint"
Cohesion: 0.22
Nodes (7): BuildingTier, .top, Footprint, .cover, .loops, Float, SIMD2

### Community 100 - "Crowd.metal"
Cohesion: 0.31
Nodes (9): crowdRotation(), JointMatrix, row0, row1, row2, float4, quatMul(), quatNlerp() (+1 more)

### Community 101 - "RTBlockInstance"
Cohesion: 0.13
Nodes (16): BVHNode, hi0, hi1, lo0, lo1, float4, RTBlockInstance, mask (+8 more)

### Community 102 - ".write"
Cohesion: 0.16
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 103 - "Camera"
Cohesion: 0.25
Nodes (8): Darwin, Camera, .forward, .right, .up, rotate(), Float, float4x4

### Community 104 - "Building"
Cohesion: 0.08
Nodes (26): Hashable, Building, .triangleCount, BuildingGenerator, BuildingSpec, Slot, accent, blind (+18 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - ".commit"
Cohesion: 0.21
Nodes (4): Launch, String, .summary, Streaming

### Community 107 - "Types.metal"
Cohesion: 0.29
Nodes (6): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, windOn()

### Community 108 - "Material"
Cohesion: 0.33
Nodes (6): Material, albedo, emission, params, textures, uint4

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 110 - "Species"
Cohesion: 0.11
Nodes (19): Mesh, Bone, Part, Plant, .height, Species, birch, bush (+11 more)

### Community 111 - "WorldTests"
Cohesion: 0.18
Nodes (7): UInt32, Data, StaticString, String, T, UInt, WorldTests

### Community 112 - "WorldTile"
Cohesion: 0.21
Nodes (12): Chunk, .triangles, ChunkRecord, Light, Float, String, UInt32, URL (+4 more)

### Community 113 - "CrowdPoseParams"
Cohesion: 0.22
Nodes (9): CrowdPoseParams, firstSlot, jointBase, jointCount, pad0, pad1, pad2, paletteStride (+1 more)

### Community 115 - "CrowdSkinParams"
Cohesion: 0.22
Nodes (9): CrowdSkinParams, bindBase, currentBase, firstSlot, paletteStride, previousBase, skinBase, slotCount (+1 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.41
Nodes (8): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, SplitMix64

### Community 118 - "CPU (Swift) practices for MetalRenderer"
Cohesion: 0.10
Nodes (17): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)) (+9 more)

### Community 119 - "Config"
Cohesion: 0.23
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Float

### Community 120 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 121 - "Flora"
Cohesion: 0.11
Nodes (15): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.18
Nodes (11): CAMetalLayer, FrameTimes, CAMetalDrawable, CFTimeInterval, Void, FeedbackCollector, CAMetalDrawable, CFTimeInterval (+3 more)

### Community 125 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 126 - "CityPlan"
Cohesion: 0.12
Nodes (17): CityPlan, Edge, open, party, street, Lot, .front, .size (+9 more)

### Community 127 - "CrowdRefitParams"
Cohesion: 0.40
Nodes (5): CrowdRefitParams, nodeBase, nodeCount, pad, tag

### Community 128 - "SkinVertex"
Cohesion: 0.40
Nodes (5): SkinVertex, joints, w0, w1, w2

### Community 129 - "CrowdJoint"
Cohesion: 0.50
Nodes (4): CrowdJoint, inverseBindRotation, inverseBindTranslation, local

### Community 131 - "DebugInfo"
Cohesion: 0.16
Nodes (11): NSColor, NSStackView, DebugInfo, Section, Float, NSCoder, String, VirtualGeometry (+3 more)

### Community 132 - ".instances"
Cohesion: 0.18
Nodes (6): GPULight, meshLights, .materialBuffers, Range, UnsafeMutableBufferPointer, UnsafeMutablePointer

### Community 133 - "PlantWind"
Cohesion: 0.24
Nodes (15): boneAngle(), coverLean(), float3, float4, uint, PlantWind, angle, axis (+7 more)

### Community 134 - "Terrain"
Cohesion: 0.29
Nodes (6): Float, SIMD2, UInt32, UInt64, Terrain, .cell

### Community 135 - "VirtualGeometry.metal"
Cohesion: 0.38
Nodes (12): coherent, constant, device, kernel, uint, vgCutKernel(), vgFinishKernel(), vgFitKernel() (+4 more)

### Community 136 - "BenchmarkModesTests"
Cohesion: 0.18
Nodes (7): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Tests, Timings, What could not be run, BenchmarkModesTests

### Community 137 - "MTLTexture"
Cohesion: 0.07
Nodes (17): FogNoise, UInt8, DenoiseSignal, DenoiseTargets, FogTargets, resourceCreation, RestirGITargets, RestirTargets (+9 more)

### Community 139 - "FrameEncoder"
Cohesion: 0.12
Nodes (13): MTL4InstanceAccelerationStructureDescriptor, MTLInstanceAccelerationStructureDescriptor, MTLPrimitiveAccelerationStructureDescriptor, FrameEncoder, PrimitiveRefit, AnyObject, MTLAccelerationStructure, MTLAccelerationStructureUsage (+5 more)

### Community 140 - "RTPart"
Cohesion: 0.17
Nodes (12): RTPart, blasRoot, bough, boughAxis, firstLeaf, leafCount, limb, limbAxis (+4 more)

### Community 141 - "Map"
Cohesion: 0.12
Nodes (12): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, MTLCommandQueue, MTLDevice (+4 more)

### Community 143 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 144 - "SettingsStore"
Cohesion: 0.20
Nodes (6): DispatchWorkItem, base, .settings, SettingsStore, Any, String

### Community 145 - "CharacterImporter"
Cohesion: 0.26
Nodes (10): simd_quatd, CharacterImporter, Mapping, controlPoint, polygonVertex, Skeleton, .bindPositions, .bindRotations (+2 more)

### Community 146 - "BVHTests"
Cohesion: 0.24
Nodes (6): BVHTests, Float, StaticString, String, UInt, UInt64

### Community 147 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.20
Nodes (10): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, StreamPick (+2 more)

### Community 148 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 149 - "Hit"
Cohesion: 0.22
Nodes (9): Hit, barycentrics, cluster, distance, hit, instance, part, primitive (+1 more)

### Community 150 - "Metal"
Cohesion: 0.33
Nodes (3): Metal, MetalFX, QuartzCore

### Community 152 - ".encode"
Cohesion: 0.33
Nodes (5): Float, MTLComputePipelineState, MTLTexture, SIMD2, TemporalUpscaler

### Community 153 - "SceneBuffersTests"
Cohesion: 0.15
Nodes (10): GPUMesh, UInt64, made, SceneBuffersTests, Float, MeshGeometry, MTLBuffer, String (+2 more)

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "Measuring MetalRenderer"
Cohesion: 0.15
Nodes (10): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer (+2 more)

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "AABB"
Cohesion: 0.22
Nodes (7): AABB, .area, .centroid, .isEmpty, BinScratch, float4x4, .bounds

### Community 158 - "VGInstance"
Cohesion: 0.20
Nodes (10): float4, float4x4, VGInstance, clusterBase, clusterCount, hi, instance, lo (+2 more)

### Community 159 - "RTInstance"
Cohesion: 0.25
Nodes (8): RTInstance, blasRoot, mask, pad0, pad1, row0, row1, row2

### Community 160 - "Modes"
Cohesion: 0.19
Nodes (4): Render something: `scripts/render.sh`, 6. Math, Modes, Images

### Community 161 - "VGParams"
Cohesion: 0.20
Nodes (10): VGParams, camPos, capacity, frame, instanceCount, nodeBase, pad, requestCapacity (+2 more)

### Community 162 - "ImageIO"
Cohesion: 0.33
Nodes (3): CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - ".init"
Cohesion: 0.50
Nodes (3): CGRect, MTLDevice, NSCoder

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 166 - "Contents"
Cohesion: 0.28
Nodes (5): Contents, unsupported, MappedFile, UnsafeRawPointer, URL

### Community 167 - "Custom"
Cohesion: 0.22
Nodes (9): Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, skyImage, skyMode (+1 more)

### Community 168 - "VGCluster"
Cohesion: 0.22
Nodes (9): VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere, selfSphere (+1 more)

### Community 169 - "TextureStreamerTests"
Cohesion: 0.33
Nodes (3): .residentLevels, URL, TextureStreamerTests

### Community 170 - "XCTestCase"
Cohesion: 0.29
Nodes (5): CacheTests, String, URL, GLTFLoaderTests, XCTestCase

### Community 171 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 173 - "RendererError"
Cohesion: 0.47
Nodes (4): MTLDevice, RendererError, .description, missingFunction

### Community 174 - "VGBlas"
Cohesion: 0.33
Nodes (6): VGBlas, attrs, nodes, pad, triangles, tris

### Community 175 - "Builder"
Cohesion: 0.40
Nodes (5): Builder, hybrid, sah, spliced, String

### Community 176 - "Part"
Cohesion: 0.50
Nodes (4): Part, built, .count, split

### Community 177 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

## Knowledge Gaps
- **824 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `split` (+819 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1195 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **15 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Equatable`, `Frame`, `FBXFile`, `.simplify`, `Benchmark`, `Bool`, `.drawFrame`, `GPUProfiler`, `Metal4Frame`, `.addLight`, `.meshes`, `MTKView`, `LightTable`, `TextureStreamer`, `SIMD4`, `Kernel`, `SettingsPanel`, `Renderer`, `SceneSettings`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `Mesh`, `RenderAPI`, `SceneBuffers`, `Crowd`, `.int`, `DebugPanel`, `SceneKind`, `SkyImage`, `CustomRayTracer`, `Rect`, `Int32`, `Metal3Pass`, `FoliageVoxels`, `VirtualBLAS`, `.buildBLAS`, `Pipelines`, `FBXError`, `World`, `.build`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `MeshBuilder`, `GLTFModel`, `Footprint`, `.write`, `Building`, `.commit`, `Species`, `WorldTile`, `BuildingAssembler`, `Config`, `WorldPlace`, `Flora`, `.commit`, `VoxelLOD`, `CityPlan`, `DebugInfo`, `.instances`, `Terrain`, `MTLTexture`, `FrameEncoder`, `FoliageRuntimeTests`, `LightKind`, `CharacterImporter`, `BVHTests`, `SplitMix64`, `.encode`, `SceneBuffersTests`, `Phyllotaxis`, `Modes`, `Contents`, `TextureStreamerTests`, `.bind`, `RendererError`, `Part`, `.runTest`?**
  _High betweenness centrality (0.318) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `DebugInfo`, `Equatable`, `Frame`, `FBXFile`, `.simplify`, `Benchmark`, `MTLTexture`, `.instances`, `FrameEncoder`, `RenderView`, `GPUProfiler`, `Metal4Frame`, `.addLight`, `LightKind`, `.meshes`, `FoliageRuntimeTests`, `TextureStreamer`, `.encode`, `Int`, `SceneBuffersTests`, `Kernel`, `AABB`, `Renderer`, `SceneSettings`, `SettingsPanel`, `SectionFile`, `Mesh`, `RenderAPI`, `Shape`, `.bind`, `RendererError`, `SceneBuffers`, `TextureStreamerTests`, `AppDelegate`, `Crowd`, `DebugPanel`, `SceneKind`, `CustomRayTracer`, `Rect`, `Int32`, `FoliageVoxels`, `VirtualBLAS`, `.buildBLAS`, `Pipelines`, `FBXError`, `.load`, `World`, `.build`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `MeshBuilder`, `Footprint`, `Building`, `Species`, `WorldTile`, `BuildingAssembler`, `Config`, `Flora`, `.commit`, `VoxelLOD`, `CityPlan`?**
  _High betweenness centrality (0.181) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirGIInitialKernel`, `Map`, `MTKView`, `Kernel`, `reflectionKernel`?**
  _High betweenness centrality (0.170) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `Renderer` (e.g. with `.parts` and `GPUSkyParams`) actually correct?**
  _`Renderer` has 3 INFERRED edges - model-reasoned connections that need verification._
- **Are the 15 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.debugInfo()`) actually correct?**
  _`Scene` has 15 INFERRED edges - model-reasoned connections that need verification._
- **Are the 19 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.load()`) actually correct?**
  _`SIMD3` has 19 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _824 weakly-connected nodes found - possible documentation gaps or missing edges._