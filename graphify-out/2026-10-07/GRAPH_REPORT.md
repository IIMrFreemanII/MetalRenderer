# Graph Report - MetalGI  (2026-10-04)

## Corpus Check
- 141 files · ~1,036,214 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 21 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 3)

## Summary
- 3841 nodes · 10921 edges · 172 communities (160 shown, 12 thin omitted)
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 1520 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `79fb8330`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- SceneSettings
- Lights.metal
- GPUProfiler
- .part
- .simplify
- Benchmark
- evalcommon.py
- RenderSettings
- RenderView
- rcTraceMergeKernel
- .drawFrame
- Metal3Frame
- Metal4Frame
- .init
- .meshes
- atrousKernel
- Fog.metal
- Sky.metal
- OffscreenSurface
- LightTable
- TextureStreamer
- Int
- LightSampling.metal
- SIMD4
- Output.metal
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
- BVHBuild.metal
- Uniforms
- Mesh
- String
- Direct Lighting Reference Scene
- SceneBuffers
- RegirParams
- 3D Rendered Scene with Geometric Primitives
- Geometric Test Primitives
- AppDelegate
- Crowd
- FBXFile
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
- VGBlas
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
- CityPlan
- Int32
- simd
- Metal3Pass
- FoliageVoxels
- VirtualBLAS
- AABB
- Pipelines
- ab.sh
- ShadingPoint
- CharacterLibrary
- Intersect.metal
- EmissiveTriangle
- .load
- Double
- RendererController
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
- RenderAPI
- Camera
- Building
- BuildingStyle
- EnvVariable
- Types.metal
- Material
- MeshData
- Species
- CityStyle
- WorldTile
- CrowdPoseParams
- MetalRenderer
- CrowdSkinParams
- render.sh
- Bool
- .draw
- .addLight
- Shaders.metal
- Flora
- same.sh
- .commit
- baseline.sh
- VoxelLOD
- CityTests
- CrowdRefitParams
- SkinVertex
- CrowdJoint
- Slot
- DebugInfo
- .init
- PlantWind
- .buildWorld
- VirtualGeometry.metal
- XCTestCase
- MTLTexture
- .useResource
- TLASUpdate
- RTPart
- KernelVariantsTests
- .library
- LightKind
- SettingsStore
- Performance in MetalRenderer
- LayerSurface
- GPU (Metal / MSL) practices for MetalRenderer
- .capture
- Hit
- Metal
- SplitMix64
- ComputePass
- SceneBuffersTests
- Crown
- Measuring MetalRenderer
- Phyllotaxis
- InputHandler
- VGInstance
- RTInstance
- RenderThread
- VGParams
- ImageIO
- .init
- related.sh
- InstanceData
- RTVoxels
- .setFrameSize
- VGCluster
- Shape
- Builder
- LightMotion

## God Nodes (most connected - your core abstractions)
1. `Renderer` - 200 edges
2. `Scene` - 178 edges
3. `SIMD3` - 165 edges
4. `Foliage` - 88 edges
5. `RenderSettings` - 88 edges
6. `Benchmark` - 87 edges
7. `Kernel` - 74 edges
8. `Config` - 69 edges
9. `Metal4Frame` - 58 edges
10. `SIMD4` - 53 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift
- `Map` --references--> `Capabilities`  [INFERRED]
  .claude/skills/tests/SKILL.md → Sources/MetalRenderer/Capabilities.swift

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

## Communities (172 total, 12 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.06
Nodes (38): GPUEmissiveTriangle, meshLights, .windFrame, Assembly, Bone, BorrowedLight, BorrowedMesh, BorrowedTree (+30 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.18
Nodes (31): Buffer, Decodable, Decoder, Node, Accessor, AnyDecodable, Asset, Buffer (+23 more)

### Community 3 - "SceneSettings"
Cohesion: 0.10
Nodes (36): Bound, Codable, Equatable, Void, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings (+28 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (64): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+56 more)

### Community 5 - "GPUProfiler"
Cohesion: 0.11
Nodes (15): MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLTimestamp, Frame, GPUProfiler, Optional (+7 more)

### Community 6 - ".part"
Cohesion: 0.15
Nodes (17): simd_double4x4, simd_quatd, FBXError, .description, StaticString, CharacterImporter, concurrently(), Mapping (+9 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Benchmark"
Cohesion: 0.09
Nodes (18): Render something: `scripts/render.sh`, 6. Math, Modes, Images, Benchmark modes: `Benchmark+Modes.swift`, Benchmark, .current, .framesInConfig (+10 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "RenderSettings"
Cohesion: 0.09
Nodes (29): F, taau, RenderSettings, Control, checkbox, custom, popup, slider (+21 more)

### Community 11 - "RenderView"
Cohesion: 0.20
Nodes (10): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, NSView, RenderView, .acceptsFirstResponder, URL (+2 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+21 more)

### Community 13 - ".drawFrame"
Cohesion: 0.20
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, FrameEncoder, CompositeInputs, FramePlan, .prev, FrameSize (+3 more)

### Community 14 - "Metal3Frame"
Cohesion: 0.22
Nodes (7): MTLPrimitiveAccelerationStructureDescriptor, Metal3Frame, PrimitiveRefit, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLCommandQueue, String

### Community 15 - "Metal4Frame"
Cohesion: 0.07
Nodes (32): MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTL4ComputeCommandEncoder, MTL4UpdateSparseTextureMappingOperation, MTLAllocation, MTLResidencySet (+24 more)

### Community 16 - ".init"
Cohesion: 0.34
Nodes (6): translate(), FogVolume, LightPose, Kit, Float, Void

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
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "OffscreenSurface"
Cohesion: 0.15
Nodes (13): AnyObject, Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameOutput, Headless (+5 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.09
Nodes (27): MTLRegion, MTLSparseTextureMappingMode, mappings, Entry, Level, SparseMapping, Data, MTLCommandBuffer (+19 more)

### Community 24 - "Int"
Cohesion: 0.10
Nodes (21): UInt32, .instanceDescriptorStride, Int, .envText, MTLDevice, BuddyAllocator, Group, Params (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (49): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+41 more)

### Community 26 - "SIMD4"
Cohesion: 0.13
Nodes (19): simd_quatf, GPUJoint, .parent, .worldToView, Clip, .duration, .loopKeys, Level (+11 more)

### Community 27 - "Output.metal"
Cohesion: 0.15
Nodes (35): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), clipToBox(), compositeKernel(), debugHashColor(), debugHeat() (+27 more)

### Community 28 - "Kernel"
Cohesion: 0.04
Nodes (56): Kernel, accumulate, accumulateColor, atrous, cloudNoise, cloudShadow, composite, crowdPose (+48 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.05
Nodes (42): VGView, Renderer, .activeDirectMode, .activeGIMode, .customRT, .dayTime, .denoiserOn, .emissiveBuffer (+34 more)

### Community 31 - "SettingsTableTests"
Cohesion: 0.14
Nodes (8): Settings: `SettingsTable.swift`, Things that are not structures yet, Where new code belongs, .outputs, SettingsEnv, String, SettingsTableTests, String

### Community 32 - "traceKernel"
Cohesion: 0.10
Nodes (44): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), fireflyScale(), luminance(), makeSampler(), constant (+36 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.07
Nodes (51): constant, device, float2, float3, kernel, thread, uint, regirBuildKernel() (+43 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.16
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.17
Nodes (15): simd_float4x4, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUPoseSlot, GPURegirReservoir, GPURestirGIParams, .initialPassFlags (+7 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.07
Nodes (25): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, R, Section, Section, GeneratedCache, Hasher, SectionFile (+17 more)

### Community 39 - "BVHBuild.metal"
Cohesion: 0.18
Nodes (24): 5. Reductions, atomics and threadgroup memory, boxToWorld(), KarrasRange, first, last, split, coherent, constant (+16 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.15
Nodes (17): Plant, Skeleton, LeafShape, blade, kite, needle, Mesh, .leafTriangles (+9 more)

### Community 42 - "String"
Cohesion: 0.07
Nodes (33): DirectLightMode, auto, exact, grouped, restir, .title, MetalPlantVoxels, auto (+25 more)

### Community 43 - "Direct Lighting Reference Scene"
Cohesion: 0.20
Nodes (10): Colored Environment Walls, Cube Object, Direct Lighting Reference Scene, Geometric Primitives, Point Light Source, Material Properties, Rectangular Prism Object, Rendering Quality Evaluation Reference (+2 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (36): MTLDevice, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction, InstanceBlock (+28 more)

### Community 45 - "RegirParams"
Cohesion: 0.33
Nodes (6): float4, uint4, RegirParams, config, consume, origin

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
Nodes (19): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+11 more)

### Community 50 - "FBXFile"
Cohesion: 0.12
Nodes (21): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+13 more)

### Community 51 - "DebugPanel"
Cohesion: 0.18
Nodes (7): NSWindowDelegate, DebugPanel, .wasVisible, CFTimeInterval, Notification, NSPanel, NSWindow

### Community 52 - "SceneKind"
Cohesion: 0.07
Nodes (28): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+20 more)

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
Cohesion: 0.24
Nodes (7): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, String, CapabilitiesTests, .none, Void

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.05
Nodes (74): RTPart, makeRay(), level, ggxFromDirection(), lightSpecular(), constant, device, float3 (+66 more)

### Community 62 - "VGBlas"
Cohesion: 0.11
Nodes (18): device, VGBlas, attrs, nodes, pad, triangles, tris, VGClusterView (+10 more)

### Community 63 - "SceneShading"
Cohesion: 0.17
Nodes (12): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+4 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "SkyImage"
Cohesion: 0.23
Nodes (9): Error, Atmosphere, LoadError, unreadable, SkyImage, Float, Set, String (+1 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "CustomRayTracer"
Cohesion: 0.09
Nodes (21): CustomRayTracer, .buffers, .dynamicNodeBase, .dynamicRoot, .virtualNodeBase, RefitParams, RTInstance, RTPart (+13 more)

### Community 73 - "CityPlan"
Cohesion: 0.11
Nodes (26): .area, Block, CityPlan, Edge, open, party, street, Lamp (+18 more)

### Community 74 - "Int32"
Cohesion: 0.41
Nodes (6): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 75 - "simd"
Cohesion: 0.15
Nodes (4): Foundation, simd, FogNoise, UInt8

### Community 76 - "Metal3Pass"
Cohesion: 0.11
Nodes (11): Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder, MTLComputePipelineState, MTLSize (+3 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.10
Nodes (21): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, String, UInt32 (+13 more)

### Community 78 - "VirtualBLAS"
Cohesion: 0.16
Nodes (16): CutInput, Entry, Float, float4x4, MTLBuffer, MTLDevice, MTLResource, Range (+8 more)

### Community 79 - "AABB"
Cohesion: 0.10
Nodes (28): AABB, .area, .centroid, .isEmpty, BinScratch, BLASResult, BVHBuilder, BVHNode (+20 more)

### Community 80 - "Pipelines"
Cohesion: 0.25
Nodes (14): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, KernelVariants, .count, Key, Pipelines, .rc (+6 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "ShadingPoint"
Cohesion: 0.22
Nodes (9): ShadingPoint, albedo, f0, n, ng, p, roughness, specular (+1 more)

### Community 83 - "CharacterLibrary"
Cohesion: 0.25
Nodes (7): BlobReader, BlobWriter, CharacterLibrary, .directory, Data, T, URL

### Community 84 - "Intersect.metal"
Cohesion: 0.21
Nodes (26): intersection_params, intersectAny(), intersectClosest(), intersectClosestCost(), intersectDistance(), constant, float3, SCENE_ACCEL (+18 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.19
Nodes (8): Failure, ShaderSource, String, URL, Substring, ShaderSourceTests, String, URL

### Community 87 - "Double"
Cohesion: 0.07
Nodes (31): Launch, String, .summary, Double, Float, SIMD2, UInt32, UInt64 (+23 more)

### Community 88 - "RendererController"
Cohesion: 0.15
Nodes (9): RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus, Float, NSEvent, String (+1 more)

### Community 89 - "Foliage"
Cohesion: 0.18
Nodes (16): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+8 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (17): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+9 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.05
Nodes (41): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, Hashable, BlueNoise, .cacheURL (+33 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

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
Nodes (22): CustomStringConvertible, GLTFError, .description, invalid, unsupported, GLTFModel, .bounds, .triangleCount (+14 more)

### Community 98 - "SceneData"
Cohesion: 0.08
Nodes (27): bindLightSampling(), bindShading(), constant, device, texture2d_array, uint4, SceneData, cloudShadow (+19 more)

### Community 99 - "Footprint"
Cohesion: 0.20
Nodes (9): BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops, Float, SIMD2 (+1 more)

### Community 100 - "Crowd.metal"
Cohesion: 0.31
Nodes (9): crowdRotation(), JointMatrix, row0, row1, row2, float4, quatMul(), quatNlerp() (+1 more)

### Community 101 - "RTBlockInstance"
Cohesion: 0.15
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, float4, RTBlockInstance, mask (+6 more)

### Community 102 - "RenderAPI"
Cohesion: 0.16
Nodes (15): 8. Pipelines and resources, LoadOptions, PreparedScene, .loadOptions, Replaced, AnyObject, MTLAccelerationStructure, RayTracerKind (+7 more)

### Community 103 - "Camera"
Cohesion: 0.26
Nodes (9): Darwin, Camera, .forward, .right, .up, rotate(), scale(), Float (+1 more)

### Community 104 - "Building"
Cohesion: 0.19
Nodes (9): Building, .triangleCount, BuildingGenerator, SurfaceMaterial, .uvScale, float4x4, BuildingTests, Float (+1 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.10
Nodes (21): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+13 more)

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
Cohesion: 0.12
Nodes (22): CaseIterable, Mesh, Age, mature, sapling, young, Bone, Part (+14 more)

### Community 111 - "CityStyle"
Cohesion: 0.14
Nodes (10): Float, World, CityStyle, mixed, modern, office, oldtown, residential (+2 more)

### Community 112 - "WorldTile"
Cohesion: 0.07
Nodes (36): GPUMaterial, Float, SIMD2, World, World, .anchorTile, .start, WorldPlace (+28 more)

### Community 113 - "CrowdPoseParams"
Cohesion: 0.22
Nodes (9): CrowdPoseParams, firstSlot, jointBase, jointCount, pad0, pad1, pad2, paletteStride (+1 more)

### Community 115 - "CrowdSkinParams"
Cohesion: 0.22
Nodes (9): CrowdSkinParams, bindBase, currentBase, firstSlot, paletteStride, previousBase, skinBase, slotCount (+1 more)

### Community 117 - "Bool"
Cohesion: 0.18
Nodes (13): OptionSet, BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2 (+5 more)

### Community 118 - ".draw"
Cohesion: 0.10
Nodes (18): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, The pass, The pass after a feature (+10 more)

### Community 119 - ".addLight"
Cohesion: 0.29
Nodes (5): Scene kinds: `SceneKind` in `Settings.swift`, GPUMesh, UInt64, String, MeshGeometry

### Community 120 - "Shaders.metal"
Cohesion: 0.15
Nodes (14): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+6 more)

### Community 121 - "Flora"
Cohesion: 0.10
Nodes (16): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - ".commit"
Cohesion: 0.18
Nodes (11): CAMetalLayer, FrameTimes, CAMetalDrawable, CFTimeInterval, Void, FeedbackCollector, CAMetalDrawable, CFTimeInterval (+3 more)

### Community 125 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 127 - "CrowdRefitParams"
Cohesion: 0.40
Nodes (5): CrowdRefitParams, nodeBase, nodeCount, pad, tag

### Community 128 - "SkinVertex"
Cohesion: 0.40
Nodes (5): SkinVertex, joints, w0, w1, w2

### Community 129 - "CrowdJoint"
Cohesion: 0.50
Nodes (4): CrowdJoint, inverseBindRotation, inverseBindTranslation, local

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "DebugInfo"
Cohesion: 0.14
Nodes (12): NSColor, NSStackView, DebugInfo, Section, Float, NSCoder, NSTextField, String (+4 more)

### Community 132 - ".init"
Cohesion: 0.10
Nodes (12): GPUFogParams, .reflectionPassFlags, GPULight, GPURegirParams, GPUSkyParams, .instanceDataBuffers, .materialBuffers, resourceCreation (+4 more)

### Community 133 - "PlantWind"
Cohesion: 0.24
Nodes (15): boneAngle(), coverLean(), float3, float4, uint, PlantWind, angle, axis (+7 more)

### Community 134 - ".buildWorld"
Cohesion: 0.21
Nodes (9): Instance, .isStatic, .moves, InstanceGroup, String, UInt32, TextureSource, .identity (+1 more)

### Community 135 - "VirtualGeometry.metal"
Cohesion: 0.38
Nodes (12): coherent, constant, device, kernel, uint, vgCutKernel(), vgFinishKernel(), vgFitKernel() (+4 more)

### Community 136 - "XCTestCase"
Cohesion: 0.11
Nodes (10): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Tests, Timings, What could not be run, BenchmarkModesTests, ForestTests (+2 more)

### Community 137 - "MTLTexture"
Cohesion: 0.12
Nodes (11): MetalKit, DenoiseSignal, DenoiseTargets, FogTargets, RestirGITargets, RestirTargets, ShadowTargets, MTLDevice (+3 more)

### Community 139 - "TLASUpdate"
Cohesion: 0.20
Nodes (7): MTL4InstanceAccelerationStructureDescriptor, MTLInstanceAccelerationStructureDescriptor, MTLAccelerationStructure, MTLAccelerationStructureUsage, TLASUpdate, .descriptor, .descriptor4

### Community 140 - "RTPart"
Cohesion: 0.17
Nodes (12): RTPart, blasRoot, bough, boughAxis, firstLeaf, leafCount, limb, limbAxis (+4 more)

### Community 141 - "KernelVariantsTests"
Cohesion: 0.33
Nodes (3): KernelVariantsTests, String, UInt32

### Community 143 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 144 - "SettingsStore"
Cohesion: 0.22
Nodes (5): DispatchWorkItem, base, SettingsStore, Any, String

### Community 145 - "Performance in MetalRenderer"
Cohesion: 0.19
Nodes (6): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop

### Community 146 - "LayerSurface"
Cohesion: 0.20
Nodes (9): CGSize, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, MTLDevice (+1 more)

### Community 147 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.20
Nodes (10): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, StreamPick (+2 more)

### Community 148 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 149 - "Hit"
Cohesion: 0.25
Nodes (8): Hit, barycentrics, cluster, hit, instance, part, primitive, float2

### Community 150 - "Metal"
Cohesion: 0.22
Nodes (3): Metal, MetalFX, QuartzCore

### Community 152 - "ComputePass"
Cohesion: 0.10
Nodes (20): ComputePass, MTLHeap, MTLResource, MTLResourceUsage, MTLComputePipelineState, LBVHCounts, buffer, bytes (+12 more)

### Community 153 - "SceneBuffersTests"
Cohesion: 0.18
Nodes (8): made, SceneBuffersTests, Float, MeshGeometry, MTLBuffer, String, T, Void

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "Measuring MetalRenderer"
Cohesion: 0.33
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "InputHandler"
Cohesion: 0.20
Nodes (3): InputHandler, Float, NSEvent

### Community 158 - "VGInstance"
Cohesion: 0.20
Nodes (10): float4, float4x4, VGInstance, clusterBase, clusterCount, hi, instance, lo (+2 more)

### Community 159 - "RTInstance"
Cohesion: 0.25
Nodes (8): RTInstance, blasRoot, mask, pad0, pad1, row0, row1, row2

### Community 160 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 161 - "VGParams"
Cohesion: 0.20
Nodes (10): VGParams, camPos, capacity, frame, instanceCount, nodeBase, pad, requestCapacity (+2 more)

### Community 162 - "ImageIO"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - ".init"
Cohesion: 0.50
Nodes (3): CGRect, MTLDevice, NSCoder

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGCluster"
Cohesion: 0.22
Nodes (9): VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere, selfSphere (+1 more)

### Community 171 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 175 - "Builder"
Cohesion: 0.40
Nodes (5): Builder, hybrid, sah, spliced, String

### Community 177 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

## Knowledge Gaps
- **831 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+826 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1207 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **12 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `Slot`, `DebugInfo`, `GLTFLoader`, `GPUProfiler`, `.part`, `.init`, `Benchmark`, `.simplify`, `MTLTexture`, `TLASUpdate`, `.buildWorld`, `.drawFrame`, `Metal3Frame`, `.library`, `Metal4Frame`, `LightKind`, `LayerSurface`, `.init`, `SceneSettings`, `OffscreenSurface`, `LightTable`, `SplitMix64`, `ComputePass`, `SceneBuffersTests`, `SIMD4`, `TextureStreamer`, `Phyllotaxis`, `Kernel`, `Renderer`, `SettingsPanel`, `RadianceCascades`, `SectionFile`, `Mesh`, `String`, `SceneBuffers`, `Crowd`, `FBXFile`, `DebugPanel`, `RenderSettings`, `SceneKind`, `SkyImage`, `CustomRayTracer`, `CityPlan`, `Int32`, `Metal3Pass`, `FoliageVoxels`, `VirtualBLAS`, `AABB`, `Pipelines`, `.meshes`, `Double`, `RendererController`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `MeshBuilder`, `GLTFModel`, `Footprint`, `RenderAPI`, `Building`, `EnvVariable`, `Species`, `CityStyle`, `WorldTile`, `Bool`, `.draw`, `.addLight`, `Flora`, `.commit`, `VoxelLOD`, `CityTests`?**
  _High betweenness centrality (0.355) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `Kernel`, `reflectionKernel`, `SettingsTableTests`?**
  _High betweenness centrality (0.186) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `DebugInfo`, `.init`, `GPUProfiler`, `.part`, `.simplify`, `Benchmark`, `MTLTexture`, `.buildWorld`, `TLASUpdate`, `RenderView`, `.drawFrame`, `Metal3Frame`, `.library`, `Metal4Frame`, `LightKind`, `LayerSurface`, `.init`, `SceneSettings`, `.meshes`, `TextureStreamer`, `ComputePass`, `Int`, `SceneBuffersTests`, `Kernel`, `InputHandler`, `Renderer`, `SettingsTableTests`, `RenderThread`, `SettingsPanel`, `SectionFile`, `Mesh`, `String`, `Shape`, `SceneBuffers`, `AppDelegate`, `Crowd`, `DebugPanel`, `RenderSettings`, `SceneKind`, `CustomRayTracer`, `CityPlan`, `Int32`, `FoliageVoxels`, `VirtualBLAS`, `AABB`, `Pipelines`, `CharacterLibrary`, `.load`, `Double`, `RendererController`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `Upscaler`, `MeshBuilder`, `Footprint`, `RenderAPI`, `Building`, `EnvVariable`, `Species`, `WorldTile`, `.draw`, `.addLight`, `Flora`, `.commit`, `VoxelLOD`, `CityTests`?**
  _High betweenness centrality (0.183) - this node is a cross-community bridge._
- **Are the 5 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `.parts`) actually correct?**
  _`Renderer` has 5 INFERRED edges - model-reasoned connections that need verification._
- **Are the 15 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.debugInfo()`) actually correct?**
  _`Scene` has 15 INFERRED edges - model-reasoned connections that need verification._
- **Are the 20 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 20 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _831 weakly-connected nodes found - possible documentation gaps or missing edges._