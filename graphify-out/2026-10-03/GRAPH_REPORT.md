# Graph Report - MetalGI  (2026-10-03)

## Corpus Check
- 84 files · ~639,747 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 15 file(s) not represented in the graph (top: .glb 11, (none) 3, .gltf 1)

## Summary
- 2252 nodes · 5946 edges · 105 communities (99 shown, 6 thin omitted)
- Extraction: 87% EXTRACTED · 13% INFERRED · 0% AMBIGUOUS · INFERRED: 759 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `82e3f9ab`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- LightKind
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Settings.swift
- Lights.metal
- GPUProfiler
- TextureStreamer
- Float
- Benchmark
- evalcommon.py
- Bool
- RenderView
- rcTraceMergeKernel
- .draw
- SceneData
- reflectionKernel
- .addMaterial
- SettingsTable.swift
- flagOn
- Fog.metal
- Sky.metal
- BuddyAllocator
- LightTable
- .makeBuffer
- Int
- LightSampling.metal
- VirtualGeometry
- Output.metal
- Kernel
- SettingsPanel
- Renderer
- SettingsTableTests
- traceKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- Intersect.metal
- 3D Scene Composition
- fogInjectKernel
- BVHBuild.metal
- Uniforms
- .encode
- .grow
- Direct Lighting Reference Scene
- Surface
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- Geometric Test Primitives
- AppDelegate
- RayTracerKind
- Hit
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- RTScene
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- SectionHeader
- FogParams
- Surface.metal
- VGBlas
- SceneShading
- Direct Rendering Stress Test 32
- GPUTypes.swift
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- CustomRayTracer
- .clusterize
- .encodeOutput
- Foundation
- BVHNode
- EnvVariable
- VirtualBLAS
- AABB
- Pipelines
- ab.sh
- ShadingPoint
- Scene
- Ray
- EmissiveTriangle
- .load
- GPU (Metal / MSL) practices for MetalRenderer
- .flatten
- Custom
- SplitMix64
- LightTableEntry
- SkyParams
- LightMotion
- GLTFModel
- TraversalStats
- GPUMaterial
- InstanceData
- AppKit
- MetalRenderer
- RTInstance
- SkyImage
- Types.metal
- Material
- MeshData

## God Nodes (most connected - your core abstractions)
1. `Renderer` - 163 edges
2. `Scene` - 92 edges
3. `RenderSettings` - 70 edges
4. `SIMD3` - 69 edges
5. `Kernel` - 67 edges
6. `Benchmark` - 62 edges
7. `Config` - 51 edges
8. `traceKernel()` - 44 edges
9. `SettingsPanel` - 41 edges
10. `reflectionKernel()` - 39 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `1. Frame structure and submission` --references--> `GPUProfiler`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/GPUProfiler.swift
- `8. Pipelines and resources` --references--> `Kernel`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Pipelines.swift
- `Narrowing and overriding` --references--> `Kernel`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Pipelines.swift
- `8. Pipelines and resources` --references--> `Pipelines`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Pipelines.swift

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

## Communities (105 total, 6 thin omitted)

### Community 0 - "LightKind"
Cohesion: 0.17
Nodes (11): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+3 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.13
Nodes (36): CustomStringConvertible, Decodable, Decoder, Node, Accessor, AnyDecodable, Asset, Buffer (+28 more)

### Community 3 - "Settings.swift"
Cohesion: 0.19
Nodes (19): Bound, Codable, Equatable, CascadeSettings, ClosedRange, DenoiserSettings, ExtraModel, FogSettings (+11 more)

### Community 4 - "Lights.metal"
Cohesion: 0.09
Nodes (58): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+50 more)

### Community 5 - "GPUProfiler"
Cohesion: 0.11
Nodes (16): MTLAccelerationStructureCommandEncoder, MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLTimestamp, Frame (+8 more)

### Community 6 - "TextureStreamer"
Cohesion: 0.07
Nodes (32): MetalFX, MTLFXSpatialScaler, MTLFXTemporalScaler, MTLHeap, MTLRegion, MaterialTextures, MTLCommandQueue, MTLDevice (+24 more)

### Community 7 - "Float"
Cohesion: 0.08
Nodes (26): Atmosphere, VGView, Mesh, SIMD2, UInt32, Camera, .forward, .right (+18 more)

### Community 8 - "Benchmark"
Cohesion: 0.07
Nodes (23): 6. Math, A/B protocol, Kernel variants, Measuring MetalRenderer, Modes, Narrowing and overriding, Reading the table, Benchmark (+15 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (33): glob, math, numpy, os, pil, re, shutil, struct (+25 more)

### Community 10 - "Bool"
Cohesion: 0.13
Nodes (22): F, RenderSettings, Bool, .envText, Control, checkbox, custom, popup (+14 more)

### Community 11 - "RenderView"
Cohesion: 0.11
Nodes (14): AnyObject, CGRect, MTKView, NSDraggingInfo, NSDragOperation, InputHandler, RenderView, .acceptsFirstResponder (+6 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+21 more)

### Community 13 - ".draw"
Cohesion: 0.21
Nodes (11): 1. The frame loop (`Renderer.draw`), CompositeInputs, ComputeStage, FramePlan, .prev, FrameSize, .upscaling, FrameStages (+3 more)

### Community 14 - "SceneData"
Cohesion: 0.09
Nodes (22): texture2d_array, uint4, SceneData, cloudShadow, emissive, feedback, indices, instances (+14 more)

### Community 15 - "reflectionKernel"
Cohesion: 0.15
Nodes (15): metal_raytracing, metal_stdlib, constant, device, float3, kernel, read, SCENE_ACCEL (+7 more)

### Community 16 - ".addMaterial"
Cohesion: 0.33
Nodes (7): Darwin, scale(), float4x4, translate(), FogVolume, LightPose, Kit

### Community 17 - "SettingsTable.swift"
Cohesion: 0.07
Nodes (37): CaseIterable, DirectLightMode, auto, exact, grouped, restir, .title, GIMode (+29 more)

### Community 18 - "flagOn"
Cohesion: 0.09
Nodes (32): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, 2. Memory bandwidth: the default suspect for screen-space passes, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)) (+24 more)

### Community 19 - "Fog.metal"
Cohesion: 0.20
Nodes (30): FogVolume, fogAlongRay(), fogFromGrid(), fogHistory(), fogInscatter(), fogMedium(), fogNoise(), fogNoiseFactor() (+22 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (40): atmosphereExtinction(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch(), cloudNoiseKernel() (+32 more)

### Community 21 - "BuddyAllocator"
Cohesion: 0.36
Nodes (3): BinScratch, BuddyAllocator, Set

### Community 22 - "LightTable"
Cohesion: 0.54
Nodes (5): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, UInt32

### Community 23 - ".makeBuffer"
Cohesion: 0.14
Nodes (8): MTLInstanceAccelerationStructureDescriptor, GPURegirParams, resourceCreation, MTLBuffer, SIMD4, T, UInt32, MTLBuffer

### Community 24 - "Int"
Cohesion: 0.14
Nodes (12): MTLPixelFormat, DenoiseSignal, DenoiseTargets, FogTargets, RestirGITargets, RestirTargets, ShadowTargets, MTLDevice (+4 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "VirtualGeometry"
Cohesion: 0.14
Nodes (12): NSColor, NSStackView, DebugInfo, Section, Double, NSCoder, NSTextField, String (+4 more)

### Community 27 - "Output.metal"
Cohesion: 0.15
Nodes (33): sample, accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), clipToBox(), compositeKernel(), debugHashColor() (+25 more)

### Community 28 - "Kernel"
Cohesion: 0.04
Nodes (52): Kernel, accumulate, accumulateColor, atrous, cloudNoise, cloudShadow, composite, .customOnly (+44 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.15
Nodes (12): NSControl, NSGridView, NSSize, FlippedView, .isFlipped, SettingsPanel, .fittedSize, Notification (+4 more)

### Community 30 - "Renderer"
Cohesion: 0.08
Nodes (21): CGSize, MTKViewDelegate, MTLAccelerationStructure, MTLSize, ObjectIdentifier, Renderer, .activeDirectMode, .activeGIMode (+13 more)

### Community 31 - "SettingsTableTests"
Cohesion: 0.17
Nodes (4): SettingsEnv, String, SettingsTableTests, String

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (48): 3. Occupancy and registers: the default suspect for big kernels, 9. Shader helpers: use them, don't copy, groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), luminance(), makeSampler() (+40 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.08
Nodes (19): DispatchWorkItem, Cascade, RadianceCascades, RCParams, RCPipelines, MTLBuffer, MTLComputeCommandEncoder, MTLComputePipelineState (+11 more)

### Community 36 - "Intersect.metal"
Cohesion: 0.40
Nodes (9): makeRay(), constant, float3, thread, octDecode(), rtSafeInverse(), rtSlab(), rtTraverse() (+1 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "fogInjectKernel"
Cohesion: 0.23
Nodes (16): fogInjectKernel(), fogIntegrateKernel(), fogReferenceKernel(), kernel, read, read_write, SCENE_ACCEL, texture2d (+8 more)

### Community 39 - "BVHBuild.metal"
Cohesion: 0.05
Nodes (65): 5. Reductions, atomics and threadgroup memory, boxToWorld(), KarrasRange, first, last, split, coherent, constant (+57 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".encode"
Cohesion: 0.33
Nodes (5): MTLComputeCommandEncoder, MTLComputePipelineState, MTLTexture, SIMD2, TemporalUpscaler

### Community 42 - ".grow"
Cohesion: 0.18
Nodes (7): float4x4, .bounds, StaticString, BVHTests, String, UInt, UInt64

### Community 43 - "Direct Lighting Reference Scene"
Cohesion: 0.20
Nodes (10): Colored Environment Walls, Cube Object, Direct Lighting Reference Scene, Geometric Primitives, Point Light Source, Material Properties, Rectangular Prism Object, Rendering Quality Evaluation Reference (+2 more)

### Community 44 - "Surface"
Cohesion: 0.14
Nodes (14): Surface, albedo, emission, f0, geomNormal, hit, instanceId, lightEmitter (+6 more)

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
Cohesion: 0.15
Nodes (8): NSApplication, NSApplicationDelegate, AppDelegate, Any, Notification, NSWindow, URL, NSWindow

### Community 49 - "RayTracerKind"
Cohesion: 0.24
Nodes (7): LoadOptions, PreparedScene, .loadOptions, RayTracerKind, custom, metal, .title

### Community 50 - "Hit"
Cohesion: 0.25
Nodes (8): Hit, barycentrics, cluster, distance, hit, instance, primitive, float2

### Community 51 - "DebugPanel"
Cohesion: 0.11
Nodes (12): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification (+4 more)

### Community 52 - "SceneKind"
Cohesion: 0.12
Nodes (16): SceneKind, area, cornell, .dayCycle, emissive, fog, gallery, .hasLightCount (+8 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "RTScene"
Cohesion: 0.12
Nodes (16): RTScene, blas, clusters, dynamicRoot, instances, nodeInstance, pad, pool (+8 more)

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

### Community 59 - "SectionHeader"
Cohesion: 0.21
Nodes (7): NSObject, Action, SectionHeader, .expanded, NSCoder, NSStackView, Void

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.15
Nodes (30): ggxFromDirection(), lightSpecular(), bindShading(), cloudShadow(), cloudShadowAt(), fetchHitVertices(), ggxD(), giEmission() (+22 more)

### Community 62 - "VGBlas"
Cohesion: 0.17
Nodes (12): device, VGBlas, attrs, nodes, pad, triangles, tris, VGClusterView (+4 more)

### Community 63 - "SceneShading"
Cohesion: 0.17
Nodes (12): device, texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod (+4 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "GPUTypes.swift"
Cohesion: 0.11
Nodes (19): 4. CPU↔GPU data layout, simd_float4x4, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUInstanceData, GPUMesh, GPURegirReservoir (+11 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "CustomRayTracer"
Cohesion: 0.11
Nodes (21): BVHNode, CustomRayTracer, .dynamicRoot, .virtualNodeBase, LBVHCounts, buffer, bytes, RTInstance (+13 more)

### Community 73 - ".clusterize"
Cohesion: 0.42
Nodes (5): LocalIds, MeshClusterizer, Int32, UInt32, UnsafeBufferPointer

### Community 74 - ".encodeOutput"
Cohesion: 0.24
Nodes (7): CAMetalDrawable, FramePasses, CFTimeInterval, Double, MTLCommandBuffer, MTLCommandQueue, String

### Community 75 - "Foundation"
Cohesion: 0.16
Nodes (8): CoreGraphics, Foundation, ImageIO, Metal, QuartzCore, simd, FogNoise, UInt8

### Community 76 - "BVHNode"
Cohesion: 0.33
Nodes (6): BVHNode, hi0, hi1, lo0, lo1, float4

### Community 77 - "EnvVariable"
Cohesion: 0.10
Nodes (20): EnvVariable, denoise, direct, fog, fogSet, gi, .index, .isList (+12 more)

### Community 78 - "VirtualBLAS"
Cohesion: 0.06
Nodes (48): .current, Builder, hybrid, sah, spliced, CutInput, Entry, float4x4 (+40 more)

### Community 79 - "AABB"
Cohesion: 0.27
Nodes (10): AABB, .area, .centroid, .isEmpty, BLASResult, BVHBuilder, BVHNode, Node (+2 more)

### Community 80 - "Pipelines"
Cohesion: 0.25
Nodes (12): Hashable, MTLLibrary, KernelVariants, .count, Key, Pipelines, .rc, MTLComputePipelineState (+4 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "ShadingPoint"
Cohesion: 0.22
Nodes (9): ShadingPoint, albedo, f0, n, ng, p, roughness, specular (+1 more)

### Community 83 - "Scene"
Cohesion: 0.14
Nodes (15): MeshGeometry, rotate(), Instance, .isStatic, String, Scene, .lightTypeMask, Data (+7 more)

### Community 84 - "Ray"
Cohesion: 0.31
Nodes (11): intersectAny(), intersectClosest(), intersectClosestCost(), intersectDistance(), SCENE_ACCEL, uint, Ray, direction (+3 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.06
Nodes (25): Launch time, BlueNoise, .cacheURL, SplitMix64, UInt64, URL, CacheFile, Launch (+17 more)

### Community 87 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.33
Nodes (6): 10. GPU tools, 1. Frame structure and submission, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, 8. Pipelines and resources, GPU (Metal / MSL) practices for MetalRenderer

### Community 88 - ".flatten"
Cohesion: 0.33
Nodes (5): Part, built, .count, split, UnsafeMutablePointer

### Community 89 - "Custom"
Cohesion: 0.22
Nodes (9): Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, skyImage, skyMode (+1 more)

### Community 91 - "LightTableEntry"
Cohesion: 0.40
Nodes (5): LightTableEntry, alias, element, pdf, threshold

### Community 92 - "SkyParams"
Cohesion: 0.20
Nodes (10): SkyParams, cloudLayer, cloudShape, flags, ground, shadowMap, sun, sunGround (+2 more)

### Community 93 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 94 - "GLTFModel"
Cohesion: 0.22
Nodes (11): GLTFModel, .triangleCount, Image, Kind, directional, point, spot, Light (+3 more)

### Community 95 - "TraversalStats"
Cohesion: 0.28
Nodes (7): Double, String, UInt64, TraversalStats, .description, .rays, .stackOverflows

### Community 96 - "GPUMaterial"
Cohesion: 0.29
Nodes (6): GPUEmissiveTriangle, GPULight, GPUMaterial, SIMD4, meshLights, UnsafeMutableBufferPointer

### Community 97 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 98 - "AppKit"
Cohesion: 0.53
Nodes (3): AppKit, MetalKit, UniformTypeIdentifiers

### Community 101 - "RTInstance"
Cohesion: 0.25
Nodes (8): RTInstance, blasRoot, mask, pad0, pad1, row0, row1, row2

### Community 104 - "SkyImage"
Cohesion: 0.31
Nodes (7): Error, LoadError, unreadable, SkyImage, Set, SIMD4, String

### Community 107 - "Types.metal"
Cohesion: 0.33
Nodes (5): MaterialTexture, t, texture2d, RegirParams, RegirReservoir

### Community 108 - "Material"
Cohesion: 0.33
Nodes (6): Material, albedo, emission, params, textures, uint4

### Community 109 - "MeshData"
Cohesion: 0.33
Nodes (6): MeshData, firstIndex, indexCount, pad0, pad1, uint

## Knowledge Gaps
- **533 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `split` (+528 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 765 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **6 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `LightKind`, `GLTFLoader`, `Settings.swift`, `GPUProfiler`, `TextureStreamer`, `Float`, `Benchmark`, `Bool`, `.draw`, `.addMaterial`, `SettingsTable.swift`, `flagOn`, `BuddyAllocator`, `LightTable`, `.makeBuffer`, `VirtualGeometry`, `Kernel`, `SettingsPanel`, `Renderer`, `RadianceCascades`, `.encode`, `.grow`, `RayTracerKind`, `DebugPanel`, `SceneKind`, `GPUTypes.swift`, `CustomRayTracer`, `.clusterize`, `.encodeOutput`, `EnvVariable`, `VirtualBLAS`, `AABB`, `Pipelines`, `Scene`, `.load`, `.flatten`, `SplitMix64`, `GLTFModel`, `TraversalStats`, `GPUMaterial`, `SkyImage`?**
  _High betweenness centrality (0.212) - this node is a cross-community bridge._
- **Why does `traceKernel()` connect `traceKernel` to `restirGIInitialKernel`, `Intersect.metal`, `Lights.metal`, `fogInjectKernel`, `rcTraceMergeKernel`, `flagOn`, `GPU (Metal / MSL) practices for MetalRenderer`, `LightSampling.metal`, `Surface.metal`?**
  _High betweenness centrality (0.208) - this node is a cross-community bridge._
- **Why does `8. Pipelines and resources` connect `GPU (Metal / MSL) practices for MetalRenderer` to `traceKernel`, `Pipelines`, `RayTracerKind`, `Kernel`, `Renderer`?**
  _High betweenness centrality (0.174) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Renderer` (e.g. with `GPUSkyParams` and `Camera`) actually correct?**
  _`Renderer` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `Scene` (e.g. with `.debugInfo()` and `.makeFogParams()`) actually correct?**
  _`Scene` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _533 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `MetalGI Real-Time Ray Tracer` be split into smaller, more focused modules?**
  _Cohesion score 0.0519774011299435 - nodes in this community are weakly interconnected._