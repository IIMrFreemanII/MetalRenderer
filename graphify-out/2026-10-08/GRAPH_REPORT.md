# Graph Report - init-branch-7e8495  (2026-10-08)

## Corpus Check
- 228 files · ~1,239,008 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6664 nodes · 20496 edges · 252 communities (226 shown, 26 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3064 edges (avg confidence: 0.84)
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
- traceKernel
- PlantCatalog
- .simplify
- Fluid.metal
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- String
- Metal4Frame
- translate
- SDFVolume
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- flagOn
- Kernel
- SettingsPanel
- Renderer
- LoadingOverlay
- pcgHash
- restirTemporalKernel
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
- Config
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- FBXFile
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Surface.metal
- VGBlas
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
- SIMD3
- simd
- RenderPass
- VoxelGrids
- .planFrame
- BVHBuilder
- Pipelines
- ab.sh
- LoadActivity
- LumenSDF.metal
- Intersect.metal
- VirtualBLAS
- .load
- Double
- Capabilities
- Foliage
- FoliageTextures
- SurfaceKind
- RasterScene
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
- Row
- RasterClusters
- RendererController
- FluidGPU
- .pieces
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- Float
- SDFBuffers
- Int
- same.sh
- Key
- baseline.sh
- PlantTracing
- CityTests
- SDFShape
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardCaptureKernel
- TraversalStats
- PlantWind
- XCTestCase
- SectionHeader
- Benchmark
- Shape
- Metal3Pass
- VoxelLOD
- .setFrameSize
- FluidSurface.metal
- RasterClusters.metal
- Shaders.metal
- GPUMaterial
- .draw
- LayerSurface
- VSMCounters
- Role
- Hit
- QuartzCore
- .buildStress
- ComputePass
- Habitat
- Curve
- .vgdebug
- SceneShading
- Stage
- FBXError
- VirtualMesh
- TraceScene
- Ray
- AppKit
- RasterVGParams
- related.sh
- VGStreamer
- RTVoxels
- Post.metal
- VGParams
- SkyParams
- .add
- PostParams
- VSM.metal
- .writeDescriptors
- .encodeSceneUpdate
- device
- VSMView
- Lumen
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- TextureStreamerTests
- SceneBuffersTests
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SIMD4
- RasterParams
- .look
- HairTests
- AABB
- VSMInstance
- SettingsStore
- SplitMix
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- CharacterRig
- .meshes
- RagdollTests
- .bytes
- SkyImage
- PhysicsGrab
- PhysPush
- Buffer
- Terrain
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
- Bool
- float4
- RenderThread
- PhysicsSkinAttach
- .begin
- Tests
- FleshFigure
- BenchmarkModesTests
- .capture
- WindFrame
- Map
- HairBSDF
- .commit
- .part
- .curve
- RenderPass4
- .used
- Heavens
- WorldPlace
- .resources
- Types.metal
- StressSceneTests
- CameraTrack
- BodyMarks
- Section
- .mark
- .useResource
- .hash
- queryGeometry
- VirtualGeometry
- .worldView
- .init
- .setComputePipelineState

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 408 edges
2. `Scene` - 300 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 259 edges
5. `Kernel` - 154 edges
6. `.length` - 145 edges
7. `SIMD4` - 142 edges
8. `Foliage` - 121 edges
9. `simd` - 117 edges
10. `Benchmark` - 110 edges

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

## Communities (252 total, 26 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (41): GPUEmissiveTriangle, BorrowedLight, CityLight, CurveMesh, Float, HairStyle, Float, UInt32 (+33 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (47): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+39 more)

### Community 3 - "RenderSettings"
Cohesion: 0.10
Nodes (42): Codable, Equatable, AgeRule, Ages, CountRule, GrassPatch, Look, Palette (+34 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (77): clipSegment(), ggxFromDirection(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular(), LightSubset (+69 more)

### Community 5 - "traceKernel"
Cohesion: 0.10
Nodes (49): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+41 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.07
Nodes (21): Foliage.Phyllotaxis, FoliageTextures.Kind, PlantCatalog, .all, .count, .covers, Decoder, Encoder (+13 more)

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "SettingsTable"
Cohesion: 0.08
Nodes (27): Bound, F, .reservoirCount, Control, checkbox, custom, popup, slider (+19 more)

### Community 11 - "RenderView"
Cohesion: 0.10
Nodes (14): AnyObject, CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder (+6 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.14
Nodes (28): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+20 more)

### Community 13 - "FramePlan"
Cohesion: 0.15
Nodes (17): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, Uniforms, Void, Uniforms, Void, CompositeInputs (+9 more)

### Community 14 - "String"
Cohesion: 0.06
Nodes (26): MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassDescriptor, MTLTimestamp, Metal3Frame (+18 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.10
Nodes (18): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, MTLStages (+10 more)

### Community 16 - "translate"
Cohesion: 0.14
Nodes (23): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, Camera, .forward, .right, .up, rotate(), scale() (+15 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

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
Nodes (76): intersectClosest(), makeRay(), constant, device, float2, float3, float4, kernel (+68 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.11
Nodes (22): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLBuffer, MTLCommandBuffer (+14 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (60): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+52 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (17): simd_double4x4, GPUJoint, Clip, .duration, .loopKeys, Level, .triangleCount, Part (+9 more)

### Community 27 - "flagOn"
Cohesion: 0.20
Nodes (25): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+17 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.16
Nodes (11): Settings: `SettingsTable.swift`, NSGridView, FlippedView, .isFlipped, SettingsPanel, .fittedSize, Notification, NSPanel (+3 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (53): 8. Pipelines and resources, done, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode, .cameraClusters (+45 more)

### Community 31 - "LoadingOverlay"
Cohesion: 0.22
Nodes (6): NSPoint, NSView, LoadingOverlay, .isEnabled, NSCoder, Timer

### Community 32 - "pcgHash"
Cohesion: 0.06
Nodes (51): constant, device, float2, float3, float4, kernel, thread, uint (+43 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.14
Nodes (30): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+22 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (46): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+38 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.19
Nodes (11): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+3 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.09
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (19): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, Stored, .array (+11 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.16
Nodes (18): Card, Skeleton, LeafAnchor, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.03
Nodes (80): CaseIterable, Body, muscles, skin, .title, DirectLightMode, auto, exact (+72 more)

### Community 43 - "VSMTargets"
Cohesion: 0.05
Nodes (37): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+29 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (42): CustomStringConvertible, .empty, MTLCommandQueue, MTLDevice, LoadOptions, .namedBlocks, .namedInstanceBlocks, .namedPrimitives (+34 more)

### Community 45 - "Config"
Cohesion: 0.12
Nodes (4): Benchmark modes: `Benchmark+Modes.swift`, Config, Float, Void

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.18
Nodes (8): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, NSWindow, URL, NSWindow

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "FBXFile"
Cohesion: 0.10
Nodes (21): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+13 more)

### Community 51 - "DebugPanel"
Cohesion: 0.08
Nodes (18): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification (+10 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (37): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+29 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.07
Nodes (29): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+21 more)

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
Cohesion: 0.16
Nodes (15): .parent, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, on (+7 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.03
Nodes (111): Material, glassKernel(), glassReflection(), constant, device, float3, kernel, read (+103 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.10
Nodes (20): Int8, Baked, bricks, heights, Heightfield, .hi, MeshSDF, .bytes (+12 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.12
Nodes (13): .virtualGeometryChanged, MTLResource, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, MTLResource, UInt32 (+5 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "SIMD3"
Cohesion: 0.10
Nodes (22): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem (+14 more)

### Community 76 - "RenderPass"
Cohesion: 0.11
Nodes (7): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, UnsafeRawPointer

### Community 77 - "VoxelGrids"
Cohesion: 0.17
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 78 - ".planFrame"
Cohesion: 0.06
Nodes (23): MetalKit, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, MaterialTextures, MTLCommandQueue, MTLDevice (+15 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.11
Nodes (17): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+9 more)

### Community 80 - "Pipelines"
Cohesion: 0.13
Nodes (21): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Pipelines (+13 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.14
Nodes (13): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled (+5 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.19
Nodes (30): anyHit(), assumeCurves(), assumeCurveShape(), candidate(), candidateIndex(), candidatePart(), card(), closestDistance() (+22 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.13
Nodes (22): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+14 more)

### Community 86 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 87 - "Double"
Cohesion: 0.17
Nodes (15): Double, World, .anchorTile, .start, Block, City, Ground, Highway (+7 more)

### Community 88 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.06
Nodes (41): Level, Mesh, Plant, RawRepresentable, Float, Age, mature, sapling (+33 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.06
Nodes (31): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+23 more)

### Community 92 - "RasterScene"
Cohesion: 0.09
Nodes (19): GPUMesh, GPURasterMesh, UInt64, Kind, arrays, block, clusters, skip (+11 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (54): groupElement(), uint4, cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi (+46 more)

### Community 95 - "FluidTests"
Cohesion: 0.09
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (13): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, UInt32 (+5 more)

### Community 99 - "Footprint"
Cohesion: 0.16
Nodes (12): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .cover (+4 more)

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
Cohesion: 0.18
Nodes (10): Building, .triangleCount, BuildingGenerator, Module, Data, float4x4, made, BuildingTests (+2 more)

### Community 105 - "SurfaceMaterial"
Cohesion: 0.09
Nodes (22): Hashable, SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle (+14 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 107 - "Row"
Cohesion: 0.17
Nodes (10): NSFont, Model, heading, item, Row, State, failed, running (+2 more)

### Community 108 - "RasterClusters"
Cohesion: 0.12
Nodes (18): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, MTLBuffer, MTLDevice (+10 more)

### Community 109 - "RendererController"
Cohesion: 0.13
Nodes (10): DebugInfo, Float, RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus, Float (+2 more)

### Community 110 - "FluidGPU"
Cohesion: 0.20
Nodes (10): Step, FluidGPU, .summary, Steps, MTLBuffer, MTLComputePipelineState, MTLDevice, UInt32 (+2 more)

### Community 111 - ".pieces"
Cohesion: 0.39
Nodes (6): Piece, SkeletonAtlas, Solid, Float, simd_float3x3, UInt32

### Community 112 - "WorldTile"
Cohesion: 0.13
Nodes (16): .time, UInt32, Chunk, .triangles, ChunkRecord, Light, Float, SIMD2 (+8 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.10
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

### Community 119 - "Float"
Cohesion: 0.07
Nodes (25): GLTFModel, .triangleCount, Material, TextureRef, Assembly, Bone, Light, .isMesh (+17 more)

### Community 120 - "SDFBuffers"
Cohesion: 0.24
Nodes (9): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+1 more)

### Community 121 - "Int"
Cohesion: 0.08
Nodes (25): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+17 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.14
Nodes (11): CodingKey, Foliage.Curve, Key, crown, linear, points, taper, Decoder (+3 more)

### Community 125 - "PlantTracing"
Cohesion: 0.14
Nodes (16): 7. Acceleration structures and ray tracing, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+8 more)

### Community 127 - "SDFShape"
Cohesion: 0.09
Nodes (28): LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer, Node, .transform, Op (+20 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardCaptureKernel"
Cohesion: 0.08
Nodes (46): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+38 more)

### Community 132 - "TraversalStats"
Cohesion: 0.12
Nodes (12): .instanceAS, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64, TraceSceneArgs (+4 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "XCTestCase"
Cohesion: 0.21
Nodes (5): GLTFLoaderTests, PipelineCacheTests, UInt32, VGStreamerTests, XCTestCase

### Community 135 - "SectionHeader"
Cohesion: 0.19
Nodes (8): NSControl, NSObject, Action, SectionHeader, .expanded, NSCoder, NSStackView, Void

### Community 136 - "Benchmark"
Cohesion: 0.10
Nodes (13): 6. Math, Modes, Images, Benchmark, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring (+5 more)

### Community 137 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 138 - "Metal3Pass"
Cohesion: 0.11
Nodes (10): Metal3Pass, .declarationScope, AnyObject, MTLBarrierScope, MTLComputeCommandEncoder, MTLComputePipelineState, MTLHeap, MTLResource (+2 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "Shaders.metal"
Cohesion: 0.11
Nodes (21): Where things are, metal_raytracing, metal_stdlib, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial() (+13 more)

### Community 144 - "GPUMaterial"
Cohesion: 0.30
Nodes (7): GPUMaterial, Assembler, Draft, Data, float4x4, UInt8, Void

### Community 145 - ".draw"
Cohesion: 0.06
Nodes (33): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants (+25 more)

### Community 146 - "LayerSurface"
Cohesion: 0.14
Nodes (15): CGSize, FrameOutput, Headless, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize (+7 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Role"
Cohesion: 0.18
Nodes (13): Role, chest, foot, forearm, hand, head, neck, pelvis (+5 more)

### Community 149 - "Hit"
Cohesion: 0.14
Nodes (14): intersection_type, committedCurve(), countedHit(), Hit, barycentrics, cluster, hit, instance (+6 more)

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (25): OptionSet, Parts, Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty (+17 more)

### Community 152 - "ComputePass"
Cohesion: 0.15
Nodes (14): ComputePass, MTLComputePipelineState, Group, PhysicsGPU, .concurrent, .hasCloth, .hasFluid, .hasHair (+6 more)

### Community 153 - "Habitat"
Cohesion: 0.29
Nodes (9): Cover, Habitat, Ramp, Float, SIMD2, UInt32, UInt64, TreePicker (+1 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - ".vgdebug"
Cohesion: 0.14
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 156 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "FBXError"
Cohesion: 0.16
Nodes (13): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+5 more)

### Community 159 - "VirtualMesh"
Cohesion: 0.14
Nodes (16): Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64, UInt8 (+8 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Ray"
Cohesion: 0.23
Nodes (13): boxCandidate(), clusterWalk(), float3, octDecode(), Ray, direction, origin, tmax (+5 more)

### Community 162 - "AppKit"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "VGStreamer"
Cohesion: 0.15
Nodes (11): BuddyAllocator, Group, Float, MTLDevice, SIMD2, UInt32, UnsafePointer, VGStreamer (+3 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - ".writeDescriptors"
Cohesion: 0.26
Nodes (6): float3x3, RTPart, Float, float4x4, UInt32, Wind

### Community 174 - ".encodeSceneUpdate"
Cohesion: 0.07
Nodes (24): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, FrameEncoder (+16 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "Lumen"
Cohesion: 0.17
Nodes (11): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+3 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.13
Nodes (12): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+4 more)

### Community 181 - "TextureStreamerTests"
Cohesion: 0.26
Nodes (3): .residentLevels, URL, TextureStreamerTests

### Community 182 - "SceneBuffersTests"
Cohesion: 0.22
Nodes (6): SceneBuffersTests, Float, MeshGeometry, MTLBuffer, T, Void

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD4"
Cohesion: 0.09
Nodes (21): GPUPhysicsShape, .worldToView, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+13 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 189 - "HairTests"
Cohesion: 0.23
Nodes (5): HairTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 190 - "AABB"
Cohesion: 0.10
Nodes (14): AABB, .area, .centroid, .isEmpty, float4x4, .bounds, BorrowedMesh, Float (+6 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 193 - "SplitMix"
Cohesion: 0.47
Nodes (3): SplitMix, Float, UInt64

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

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "CharacterRig"
Cohesion: 0.38
Nodes (6): Bone, CharacterRig, Float, float4x4, SDFShape, simd_quatf

### Community 200 - ".meshes"
Cohesion: 0.12
Nodes (4): LoadStep, MTLCommandQueue, MTLDevice, MTLDevice

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 203 - "SkyImage"
Cohesion: 0.21
Nodes (8): Error, Atmosphere, LoadError, unreadable, SkyImage, Float, Set, URL

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

### Community 213 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "Bool"
Cohesion: 0.24
Nodes (3): Float, Bool, .envText

### Community 220 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 221 - "RenderThread"
Cohesion: 0.20
Nodes (4): Notification, RenderThread, Thread, Void

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 224 - "Tests"
Cohesion: 0.27
Nodes (4): Tests, PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 225 - "FleshFigure"
Cohesion: 0.12
Nodes (17): GPUSoftVertex, .cells, Flesh, MuscleSpec, Side, back, front, out (+9 more)

### Community 227 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 228 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 229 - "Map"
Cohesion: 0.21
Nodes (9): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, Key, PipelineCache, .count (+1 more)

### Community 231 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".part"
Cohesion: 0.25
Nodes (9): simd_quatd, T, CharacterImporter, concurrently(), Skeleton, .bindPositions, .bindRotations, SourceClip (+1 more)

### Community 233 - ".curve"
Cohesion: 0.25
Nodes (6): Axis, along, front, up, Float, MeshGeometry

### Community 234 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 236 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - ".resources"
Cohesion: 0.29
Nodes (4): Float, MTLResource, UInt64, MTLBuffer

### Community 239 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 241 - "CameraTrack"
Cohesion: 0.10
Nodes (12): CameraTrack, .duration, Key, Particles, bubbles, dust, embers, none (+4 more)

### Community 243 - "Section"
Cohesion: 0.33
Nodes (4): NSColor, NSStackView, Section, NSCoder

### Community 246 - ".hash"
Cohesion: 0.40
Nodes (3): SplitMix64, UInt64, Void

### Community 247 - "queryGeometry"
Cohesion: 0.50
Nodes (5): geometry_type, intersection_params, queryGeometry(), queryParams(), voxelParams()

### Community 248 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 250 - ".init"
Cohesion: 0.50
Nodes (3): CGRect, MTLDevice, NSCoder

## Knowledge Gaps
- **1515 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1510 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2065 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **26 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `PlantCatalog`, `.simplify`, `SettingsTable`, `FramePlan`, `String`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `.write`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `Config`, `LumenScene`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `SIMD3`, `RenderPass`, `.planFrame`, `BVHBuilder`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `Double`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `RasterScene`, `Upscaler`, `FluidTests`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `Row`, `RasterClusters`, `RendererController`, `FluidGPU`, `.pieces`, `WorldTile`, `BuildingAssembler`, `Float`, `SDFBuffers`, `PlantTracing`, `CityTests`, `SDFShape`, `SettingsTableTests`, `Slot`, `TraversalStats`, `XCTestCase`, `Benchmark`, `Metal3Pass`, `VoxelLOD`, `GPUMaterial`, `LayerSurface`, `.buildStress`, `ComputePass`, `Habitat`, `Curve`, `FBXError`, `VirtualMesh`, `VGStreamer`, `.writeDescriptors`, `.encodeSceneUpdate`, `Lumen`, `LumenGlobalSDF`, `TextureStreamerTests`, `SceneBuffersTests`, `FoliageRuntimeTests`, `SIMD4`, `HairTests`, `AABB`, `CharacterRig`, `.meshes`, `RagdollTests`, `SkyImage`, `Buffer`, `Terrain`, `Bool`, `Tests`, `FleshFigure`, `WindFrame`, `Map`, `.commit`, `.part`, `.curve`, `RenderPass4`, `.used`, `WorldPlace`, `.resources`, `StressSceneTests`, `.hash`, `VirtualGeometry`, `.worldView`?**
  _High betweenness centrality (0.337) - this node is a cross-community bridge._
- **Why does `Kernel` connect `Kernel` to `Map`, `SettingsTable.swift`, `VSMTargets`, `FramePlan`, `FluidGPU`, `String`, `Pipelines`, `.draw`, `QuartzCore`, `Int`, `Renderer`?**
  _High betweenness centrality (0.137) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `restirGIInitialKernel`, `traceKernel`, `.draw`, `flagOn`, `Kernel`?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **Are the 37 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 37 INFERRED edges - model-reasoned connections that need verification._
- **Are the 27 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 27 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `PhysicsWorld` (e.g. with `GPUPhysicsGrab` and `.encodeHairCurves()`) actually correct?**
  _`PhysicsWorld` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1515 weakly-connected nodes found - possible documentation gaps or missing edges._