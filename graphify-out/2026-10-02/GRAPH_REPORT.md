# Graph Report - MetalGI  (2026-10-02)

## Corpus Check
- 45 files · ~537,515 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 15 file(s) not represented in the graph (top: .glb 11, (none) 3, .gltf 1)

## Summary
- 1562 nodes · 4067 edges · 67 communities (63 shown, 4 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 240 edges (avg confidence: 0.83)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a711cffe`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- AABB
- float3
- .clusterize
- TextureStreamer
- SettingsPanel
- Benchmark
- evalcommon.py
- uint
- RenderView
- Renderer
- float2
- traceKernel
- texture2d
- RendererError
- RayTracerKind
- .encodeCapture
- RTScene
- Uniforms
- CustomRayTracer
- RadianceCascades
- SceneKind
- .draw
- SceneData
- SkyImage
- MeshLightPoint
- Foundation
- RenderSettings
- .init
- Shaders.metal
- Surface
- ShadingPoint
- .restirGIStages
- LightTableEntry
- 3D Scene Composition
- float4
- .init
- SceneShading
- VGParams
- Direct Lighting Reference Scene
- VGCluster
- 3D Rendered Scene with Geometric Primitives
- Geometric Test Primitives
- FogParams
- InstanceData
- RTInstance
- 3D Geometric Test Scene
- VGInstance
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- BVHNode
- LightSubset
- Material
- MeshData
- Direct Rendering Stress Test 32
- GPUTypes.swift
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VGClusterView

## God Nodes (most connected - your core abstractions)
1. `Renderer` - 110 edges
2. `Scene` - 88 edges
3. `SettingsPanel` - 87 edges
4. `traceKernel()` - 35 edges
5. `Benchmark` - 34 edges
6. `reflectionKernel()` - 33 edges
7. `CustomRayTracer` - 31 edges
8. `restirGIInitialKernel()` - 30 edges
9. `TextureStreamer` - 30 edges
10. `GLTFLoader` - 29 edges

## Surprising Connections (you probably didn't know these)
- `gi.py Scorer` --conceptually_related_to--> `Path-Traced GI with NEE`  [INFERRED]
  Tools/eval/README.md → README.md
- `noise.py Scorer` --conceptually_related_to--> `Void-and-Cluster Blue-Noise Sampling`  [INFERRED]
  Tools/eval/README.md → README.md
- `Custom Two-Level BVH Ray Tracer` --references--> `pngdiff.py Image Diff`  [EXTRACTED]
  README.md → Tools/eval/README.md
- `shadow.py Scorer` --conceptually_related_to--> `Shadow Denoiser (visibility filtering)`  [INFERRED]
  Tools/eval/README.md → README.md
- `upscale.py Scorer` --conceptually_related_to--> `Custom TAAU Upscaler (taauKernel)`  [INFERRED]
  Tools/eval/README.md → README.md

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

## Communities (67 total, 4 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.07
Nodes (56): Darwin, MeshGeometry, GPUEmissiveTriangle, GPUMaterial, Float, SIMD4, Camera, .forward (+48 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.09
Nodes (55): CustomStringConvertible, Decodable, Decoder, Node, Accessor, AnyDecodable, Asset, Buffer (+47 more)

### Community 3 - "AABB"
Cohesion: 0.06
Nodes (49): AABB, .area, .centroid, .isEmpty, BLASResult, BVHBuilder, BVHNode, Node (+41 more)

### Community 4 - "float3"
Cohesion: 0.10
Nodes (57): float3, atmosphereExtinction(), atmosphereTransmittanceMarch(), clipSegment(), clipToBox(), cloudShadow(), cloudShadowAt(), fogInscatter() (+49 more)

### Community 5 - ".clusterize"
Cohesion: 0.33
Nodes (9): LocalIds, MeshClusterizer, Bool, Float, Int, Int32, SIMD3, UInt32 (+1 more)

### Community 6 - "TextureStreamer"
Cohesion: 0.15
Nodes (19): MTLHeap, MTLRegion, Entry, Level, Bool, Data, Int, MTLBuffer (+11 more)

### Community 7 - "SettingsPanel"
Cohesion: 0.03
Nodes (8): NSGridView, NSPanel, NSSize, NSWindowDelegate, .upscaleSteps, SettingsPanel, .fittedSize, Notification

### Community 8 - "Benchmark"
Cohesion: 0.12
Nodes (15): Benchmark, .current, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture, Config (+7 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.07
Nodes (32): glob, math, numpy, os, pil, re, shutil, struct (+24 more)

### Community 10 - "uint"
Cohesion: 0.07
Nodes (46): coherent, device, debugHashColor(), evalLightSample(), isVisible(), lightGroup(), LightSampleEval, diffuse (+38 more)

### Community 11 - "RenderView"
Cohesion: 0.06
Nodes (29): Any, AnyObject, AppKit, CGRect, MetalKit, MTKView, NSApplication, NSApplicationDelegate (+21 more)

### Community 12 - "Renderer"
Cohesion: 0.09
Nodes (24): MTKViewDelegate, MTLAccelerationStructure, MTLLibrary, MTLSize, ObjectIdentifier, PreparedScene, Renderer, .activeDirectMode (+16 more)

### Community 13 - "float2"
Cohesion: 0.10
Nodes (29): float2, fogAlongRay(), fogFromGrid(), fogHistory(), fogInjectKernel(), fogMedium(), fogNoise(), fogNoiseFactor() (+21 more)

### Community 14 - "traceKernel"
Cohesion: 0.12
Nodes (38): array, RC_MAX_CASCADES, SCENE_ACCEL, bindShading(), cosineSampleHemisphere(), debugHeat(), fetchHitVertices(), geometryDebugKernel() (+30 more)

### Community 15 - "texture2d"
Cohesion: 0.18
Nodes (40): kernel, read, read_write, accumulateColorKernel(), accumulateKernel(), atrousKernel(), cloudShadowKernel(), compositeKernel() (+32 more)

### Community 16 - "RendererError"
Cohesion: 0.13
Nodes (19): MetalFX, MTLFXSpatialScaler, MTLFXTemporalScaler, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, RendererError (+11 more)

### Community 17 - "RayTracerKind"
Cohesion: 0.07
Nodes (28): Bound, CaseIterable, DirectLightMode, auto, exact, grouped, restir, .title (+20 more)

### Community 18 - ".encodeCapture"
Cohesion: 0.40
Nodes (4): MTLCommandBuffer, MTLDevice, MTLTexture, Void

### Community 19 - "RTScene"
Cohesion: 0.09
Nodes (22): RTScene, blas, clusters, dynamicRoot, instances, nodeInstance, pad, pool (+14 more)

### Community 20 - "Uniforms"
Cohesion: 0.09
Nodes (22): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+14 more)

### Community 21 - "CustomRayTracer"
Cohesion: 0.06
Nodes (42): BVHNode, QuartzCore, CustomRayTracer, .dynamicRoot, .virtualNodeBase, LBVHCounts, buffer, bytes (+34 more)

### Community 22 - "RadianceCascades"
Cohesion: 0.15
Nodes (16): Cascade, RadianceCascades, RCParams, RCPipelines, Float, Int, MTLBuffer, MTLComputeCommandEncoder (+8 more)

### Community 23 - "SceneKind"
Cohesion: 0.11
Nodes (16): SceneKind, area, cornell, emissive, fog, gallery, .hasLightCount, market (+8 more)

### Community 24 - ".draw"
Cohesion: 0.17
Nodes (11): MTLPixelFormat, DenoiseTargets, FogTargets, RenderTargets, RestirGITargets, RestirTargets, ShadowTargets, Int (+3 more)

### Community 25 - "SceneData"
Cohesion: 0.12
Nodes (17): SceneData, cloudShadow, emissive, feedback, indices, instances, lightCount, lights (+9 more)

### Community 26 - "SkyImage"
Cohesion: 0.25
Nodes (11): Error, Atmosphere, LoadError, unreadable, SkyImage, Float, Int, Set (+3 more)

### Community 27 - "MeshLightPoint"
Cohesion: 0.13
Nodes (15): EmissiveTriangle, e1, e2, uv12, v0, MeshLightPoint, area2, b1 (+7 more)

### Community 28 - "Foundation"
Cohesion: 0.05
Nodes (38): CoreGraphics, Foundation, ImageIO, Metal, simd, BlueNoise, SplitMix64, Float (+30 more)

### Community 29 - "RenderSettings"
Cohesion: 0.32
Nodes (17): Equatable, CascadeSettings, ClosedRange, DenoiserSettings, ExtraModel, FogSettings, RenderSettings, RestirGISettings (+9 more)

### Community 30 - ".init"
Cohesion: 0.14
Nodes (12): NSSlider, NSTextField, NSView, Selector, FlippedView, .isFlipped, HeaderLabel, Bool (+4 more)

### Community 32 - "Shaders.metal"
Cohesion: 0.10
Nodes (41): metal_raytracing, metal_stdlib, sample, acesFilm(), atmosphereRadiance(), atmosphereTransmittance(), cloudDensity(), cloudHeight() (+33 more)

### Community 33 - "Surface"
Cohesion: 0.14
Nodes (14): Surface, albedo, emission, f0, geomNormal, hit, instanceId, lightEmitter (+6 more)

### Community 34 - "ShadingPoint"
Cohesion: 0.22
Nodes (9): ShadingPoint, albedo, f0, n, ng, p, roughness, specular (+1 more)

### Community 35 - ".restirGIStages"
Cohesion: 0.32
Nodes (5): ComputeStage, MTLCommandBuffer, MTLComputeCommandEncoder, Uniforms, Void

### Community 36 - "LightTableEntry"
Cohesion: 0.40
Nodes (5): LightTableEntry, alias, element, pdf, threshold

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "float4"
Cohesion: 0.06
Nodes (40): float4, emptyReservoir(), equalAreaOctDecode(), equalAreaOctEncode(), GIReservoir, age, flags, Lo (+32 more)

### Community 39 - ".init"
Cohesion: 0.16
Nodes (7): CGSize, MTLInstanceAccelerationStructureDescriptor, validateGPULayouts(), resourceCreation, MTKView, MTLBuffer, T

### Community 40 - "SceneShading"
Cohesion: 0.10
Nodes (20): SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky, skyParams (+12 more)

### Community 42 - "VGParams"
Cohesion: 0.20
Nodes (10): VGParams, camPos, capacity, frame, instanceCount, nodeBase, pad, requestCapacity (+2 more)

### Community 43 - "Direct Lighting Reference Scene"
Cohesion: 0.20
Nodes (10): Colored Environment Walls, Cube Object, Direct Lighting Reference Scene, Geometric Primitives, Point Light Source, Material Properties, Rectangular Prism Object, Rendering Quality Evaluation Reference (+2 more)

### Community 45 - "VGCluster"
Cohesion: 0.22
Nodes (9): VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere, selfSphere (+1 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "Geometric Test Primitives"
Cohesion: 0.22
Nodes (9): Albedo Reference Test Image, Albedo Material Property Testing, Black Reference Sphere, Blue Arc Surface, Geometric Test Primitives, Green Cube (Matte Surface), Red Cube (Matte Surface), Upscaling Algorithm Evaluation (+1 more)

### Community 48 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 49 - "InstanceData"
Cohesion: 0.25
Nodes (8): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform

### Community 50 - "RTInstance"
Cohesion: 0.25
Nodes (8): RTInstance, blasRoot, mask, pad0, pad1, row0, row1, row2

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "VGInstance"
Cohesion: 0.29
Nodes (7): VGInstance, clusterBase, clusterCount, hi, instance, lo, workBase

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

### Community 60 - "BVHNode"
Cohesion: 0.40
Nodes (5): BVHNode, hi0, hi1, lo0, lo1

### Community 61 - "LightSubset"
Cohesion: 0.40
Nodes (5): LightSubset, count, offset, scale, stride

### Community 62 - "Material"
Cohesion: 0.40
Nodes (5): Material, albedo, emission, params, textures

### Community 63 - "MeshData"
Cohesion: 0.40
Nodes (5): MeshData, firstIndex, indexCount, pad0, pad1

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "GPUTypes.swift"
Cohesion: 0.16
Nodes (13): simd_float4x4, GPUFogParams, GPUFogVolume, GPUInstanceData, GPULight, GPUMesh, GPURestirGIParams, GPURestirParams (+5 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 73 - "VGClusterView"
Cohesion: 0.40
Nodes (5): VGClusterView, nodes, positions, tris, uvs

## Knowledge Gaps
- **366 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `.progressInConfig` (+361 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 582 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Renderer` connect `Renderer` to `Scene`, `GPUTypes.swift`, `.restirGIStages`, `TextureStreamer`, `.init`, `Benchmark`, `SettingsPanel`, `RenderView`, `RendererError`, `RayTracerKind`, `CustomRayTracer`, `RadianceCascades`, `.draw`, `SkyImage`, `Foundation`, `RenderSettings`, `.init`?**
  _High betweenness centrality (0.137) - this node is a cross-community bridge._
- **Why does `Scene` connect `Scene` to `GPUTypes.swift`, `AABB`, `TextureStreamer`, `Renderer`, `RendererError`, `CustomRayTracer`, `.draw`, `Foundation`, `RenderSettings`?**
  _High betweenness centrality (0.076) - this node is a cross-community bridge._
- **Why does `CustomRayTracer` connect `CustomRayTracer` to `AABB`, `Renderer`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Renderer` (e.g. with `GPUSkyParams` and `Camera`) actually correct?**
  _`Renderer` has 2 INFERRED edges - model-reasoned connections that need verification._
- **Are the 5 inferred relationships involving `Scene` (e.g. with `.draw()` and `.makeFogParams()`) actually correct?**
  _`Scene` has 5 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _366 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.07101597009853891 - nodes in this community are weakly interconnected._