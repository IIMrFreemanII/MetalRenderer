# Graph Report - fluid-simulations-cb93e5  (2026-10-07)

## Corpus Check
- 219 files · ~1,229,340 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6515 nodes · 20055 edges · 250 communities (229 shown, 21 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3048 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `4be1a47c`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- Hair.metal
- .slots
- .simplify
- Fluid.metal
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- SDFVolume
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- geometryDebugKernel
- Kernel
- SettingsPanel
- Renderer
- LoadingOverlay
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
- .meshes
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
- reflectionKernel
- VGBlas
- SceneShading
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
- FluidSystem
- simd
- Metal3Pass
- VoxelGrids
- Int
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- EmissiveTriangle
- .load
- Double
- Capabilities
- Float
- CaseIterable
- ProceduralTextures
- SkyParams
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- .length
- MeshBuilder
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- BuildingStyle
- EnvVariable
- Types.metal
- PostParams
- MeshData
- Species
- .write
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- Float
- Key
- Foliage
- same.sh
- Config
- baseline.sh
- PlantTracing
- CityTests
- SDFShape
- Raster.metal
- SettingsTableTests
- SurfaceKind
- lumenCardRadiosityKernel
- RasterClusters
- VirtualBLAS
- XCTestCase
- LumenMeshSDF
- Benchmark
- .init
- Images
- VoxelLOD
- RendererController
- FluidSurface.metal
- RasterClusters.metal
- Shaders.metal
- uint
- .draw
- LayerSurface
- VSMCounters
- SettingsStore
- Hit
- QuartzCore
- .buildStress
- Pipelines
- LightKind
- Crown
- DirectLightMode
- Phyllotaxis
- CameraTrack
- .part
- VirtualMesh
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- TileAllocator
- RTVoxels
- Post.metal
- VGParams
- LumenRadiosityParams
- Physics.swift
- MeshSDFBuilderTests
- VSM.metal
- .writeDescriptors
- RasterScene
- device
- VSMView
- .stages
- VSMClusterArgs
- VSMScene
- Int32
- InstanceData
- SceneSettings
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- .preset
- HairTests
- .addRagdoll
- VSMInstance
- LumenCards
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- LumenSDFHit
- AABB
- RagdollTests
- .build
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
- .generate
- Bool
- Liquids
- RenderThread
- PhysicsSkinAttach
- .begin
- PlantTracingTests
- .addFleshCharacter
- .encoder
- .capture
- WindFrame
- KernelVariantsTests
- HairBSDF
- .commit
- CharacterLibrary
- RenderPass4
- .keep
- TextureStreamerTests
- Heavens
- WorldPlace
- Level
- StressSceneTests
- Section
- Particles
- .end
- VGCutTests
- .mark
- .useResource
- Placement
- Backend
- .torusKnotMesh
- Flora

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 408 edges
2. `Scene` - 296 edges
3. `PhysicsWorld` - 271 edges
4. `Renderer` - 259 edges
5. `Kernel` - 151 edges
6. `.length` - 145 edges
7. `SIMD4` - 142 edges
8. `simd` - 111 edges
9. `Benchmark` - 110 edges
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

## Communities (250 total, 21 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (40): GPUEmissiveTriangle, .viewNote, BorrowedLight, CityLight, CurveMesh, Float, Instance, .isGeometry (+32 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (49): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+41 more)

### Community 3 - "RenderSettings"
Cohesion: 0.13
Nodes (39): Bound, Codable, Equatable, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel (+31 more)

### Community 4 - "Lights.metal"
Cohesion: 0.08
Nodes (67): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+59 more)

### Community 5 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 6 - ".slots"
Cohesion: 0.23
Nodes (8): simd_quatd, StaticString, T, CharacterImporter, Skeleton, .bindPositions, .bindRotations, SourceClip

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.07
Nodes (83): FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf(), fluidCellsClearKernel() (+75 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "SettingsTable"
Cohesion: 0.08
Nodes (28): F, on, Control, checkbox, custom, popup, slider, Custom (+20 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView (+10 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.13
Nodes (18): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, Things that are not structures yet, Where new code belongs, ComputeStage, FrameEncoder, CompositeInputs (+10 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.06
Nodes (29): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+21 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (18): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, rotate(), scale(), Float, float4x4, translate(), FogVolume (+10 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.14
Nodes (29): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+21 more)

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
Cohesion: 0.13
Nodes (20): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLCommandBuffer, MTLHeap (+12 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.10
Nodes (22): SIMD2, UnsafePointer, Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer (+14 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.16
Nodes (12): GPUJoint, .parent, Clip, .duration, .loopKeys, SkinnedCharacter, .bindPoses, .triangleCount (+4 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (133): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+125 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (56): 8. Pipelines and resources, GPURegirParams, PathTracePlan, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode (+48 more)

### Community 31 - "LoadingOverlay"
Cohesion: 0.12
Nodes (14): NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item, Row (+6 more)

### Community 32 - "traceKernel"
Cohesion: 0.10
Nodes (47): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), laineKarrasPermutation(), luminance(), makeSampler(), constant (+39 more)

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
Cohesion: 0.09
Nodes (35): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+27 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.10
Nodes (16): CryptoKit, R, MeshGeometry, GeneratedCache, Hasher, SectionFile, .array, Data (+8 more)

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
Cohesion: 0.04
Nodes (55): MTLBlitCommandEncoder, MTLRenderPassDescriptor, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder, PrimaryVisibility, raster (+47 more)

### Community 43 - "VSMTargets"
Cohesion: 0.06
Nodes (34): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+26 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (41): Map, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, .empty, LoadOptions, .loadOptions (+33 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.11
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.17
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.15
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, Notification, NSWindow, URL (+1 more)

### Community 49 - ".meshes"
Cohesion: 0.10
Nodes (20): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+12 more)

### Community 50 - "FBXFile"
Cohesion: 0.12
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 51 - "DebugPanel"
Cohesion: 0.09
Nodes (15): NSWindowDelegate, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification (+7 more)

### Community 52 - "SceneKind"
Cohesion: 0.06
Nodes (36): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+28 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.07
Nodes (28): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld (+20 more)

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
Nodes (43): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+35 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.03
Nodes (122): Material, glassKernel(), glassReflection(), constant, device, float3, kernel, read (+114 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.13
Nodes (17): Int8, float4x4, Baked, bricks, heights, Heightfield, .hi, MeshSDF (+9 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.05
Nodes (31): GPUFogParams, .reflectionPassFlags, Float, UnsafeBufferPointer, .instanceAS, .instanceDescBuffers, .materialBuffers, .virtualGeometryChanged (+23 more)

### Community 73 - "CityPlan"
Cohesion: 0.09
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "FluidSystem"
Cohesion: 0.11
Nodes (18): .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem, .capacity (+10 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (17): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+9 more)

### Community 77 - "VoxelGrids"
Cohesion: 0.15
Nodes (17): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+9 more)

### Community 78 - "Int"
Cohesion: 0.05
Nodes (30): MetalKit, Frame, GPUPostParams, Range, MTLComputePipelineState, DenoiseSignal, DenoiseTargets, FogTargets (+22 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.21
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.16
Nodes (9): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Step, Set (+1 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.20
Nodes (27): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+19 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 86 - ".load"
Cohesion: 0.18
Nodes (7): CustomStringConvertible, Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 87 - "Double"
Cohesion: 0.15
Nodes (16): Double, World, .anchorTile, .start, Block, City, Ground, Highway (+8 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.16
Nodes (14): Card, Carve, Graft, Grower, LeafAnchor, LeafRecipe, Level, Recipe (+6 more)

### Community 90 - "CaseIterable"
Cohesion: 0.15
Nodes (17): CaseIterable, CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf (+9 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.17
Nodes (10): Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32, UInt8 (+2 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.10
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "MeshBuilder"
Cohesion: 0.16
Nodes (11): .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Float, float4x4 (+3 more)

### Community 99 - "Footprint"
Cohesion: 0.12
Nodes (18): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .cover (+10 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (20): ArraySlice, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, Float (+12 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.21
Nodes (8): Building, BuildingGenerator, Module, Data, float4x4, BuildingTests, Float, SIMD2

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.08
Nodes (26): EnvVariable, api, denoise, direct, fog, fogSet, gi, .index (+18 more)

### Community 107 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 108 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 110 - "Species"
Cohesion: 0.09
Nodes (23): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+15 more)

### Community 111 - ".write"
Cohesion: 0.17
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 112 - "WorldTile"
Cohesion: 0.16
Nodes (17): GPUMaterial, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+9 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.12
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
Nodes (17): GLTFModel, .bounds, .triangleCount, SDFVolume, Assembly, Bone, Part, Shape (+9 more)

### Community 120 - "Key"
Cohesion: 0.48
Nodes (4): Key, PipelineCache, .count, Value

### Community 121 - "Foliage"
Cohesion: 0.14
Nodes (15): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Config"
Cohesion: 0.15
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 125 - "PlantTracing"
Cohesion: 0.12
Nodes (18): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+10 more)

### Community 127 - "SDFShape"
Cohesion: 0.09
Nodes (30): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+22 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.11
Nodes (9): Settings: `SettingsTable.swift`, SkyMode, atmosphere, constant, image, .title, SettingsEnv, ForestTests (+1 more)

### Community 130 - "SurfaceKind"
Cohesion: 0.07
Nodes (29): Hashable, Slot, accent, blind, dark, floor, frame, glass (+21 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "RasterClusters"
Cohesion: 0.09
Nodes (19): GPURasterParams, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+11 more)

### Community 133 - "VirtualBLAS"
Cohesion: 0.05
Nodes (67): Where things are, boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3 (+59 more)

### Community 134 - "XCTestCase"
Cohesion: 0.36
Nodes (4): GLTFLoaderTests, PipelineCacheTests, UInt32, XCTestCase

### Community 135 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 136 - "Benchmark"
Cohesion: 0.07
Nodes (18): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+10 more)

### Community 137 - ".init"
Cohesion: 0.25
Nodes (6): .isCancelled, LoadStep, .isCancelled, MTLCommandQueue, MTLDevice, URL

### Community 138 - "Images"
Cohesion: 0.15
Nodes (3): 6. Math, Modes, Images

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - "RendererController"
Cohesion: 0.10
Nodes (15): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles, RendererController (+7 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "Shaders.metal"
Cohesion: 0.13
Nodes (20): metal_raytracing, metal_stdlib, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant (+12 more)

### Community 144 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (25): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants (+17 more)

### Community 146 - "LayerSurface"
Cohesion: 0.12
Nodes (18): CGSize, NSFont, NSTextField, FrameOutput, Headless, LayerSurface, .backingScale, .isVisible (+10 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 151 - ".buildStress"
Cohesion: 0.16
Nodes (12): Parts, Hall, Loop, Props, Float, float4x4, SIMD2, Zone (+4 more)

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (27): ComputePass, MTLComputePipelineState, FluidGPU, .summary, MTLBuffer, MTLComputePipelineState, MTLDevice, UInt32 (+19 more)

### Community 153 - "LightKind"
Cohesion: 0.20
Nodes (10): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+2 more)

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "DirectLightMode"
Cohesion: 0.09
Nodes (17): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+9 more)

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.09
Nodes (15): CameraTrack, .duration, Key, Float, ShowcaseLook, Stage, crypt, forge (+7 more)

### Community 158 - ".part"
Cohesion: 0.24
Nodes (9): FBXError, .description, BlobReader, Mapping, controlPoint, polygonVertex, Data, StaticString (+1 more)

### Community 159 - "VirtualMesh"
Cohesion: 0.12
Nodes (18): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+10 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "AppKit"
Cohesion: 0.23
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 170 - "Physics.swift"
Cohesion: 0.33
Nodes (4): PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 171 - "MeshSDFBuilderTests"
Cohesion: 0.23
Nodes (4): MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 173 - ".writeDescriptors"
Cohesion: 0.27
Nodes (6): Tests, float3x3, Float, float4x4, UInt32, Wind

### Community 174 - "RasterScene"
Cohesion: 0.19
Nodes (6): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLDevice, MTLTexture

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".stages"
Cohesion: 0.17
Nodes (13): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "Int32"
Cohesion: 0.10
Nodes (17): Int32, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice (+9 more)

### Community 181 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 182 - "SceneSettings"
Cohesion: 0.09
Nodes (11): SceneSettings, SIMD2, RasterSceneTests, Float, MeshGeometry, SceneBuffersTests, Float, MeshGeometry (+3 more)

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.07
Nodes (26): GPUPhysicsShape, GPURasterMesh, Float, float4x4, SDFShape, PhysicsCandidate, .middle, PhysicsManifold (+18 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".preset"
Cohesion: 0.16
Nodes (3): fog, URL, ShowcaseTests

### Community 189 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 190 - ".addRagdoll"
Cohesion: 0.22
Nodes (5): RagdollShapes, Float, float4x4, Range, SDFShape

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "LumenCards"
Cohesion: 0.18
Nodes (11): Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

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

### Community 197 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "LumenSDFHit"
Cohesion: 0.29
Nodes (7): LumenSDFHit, hit, id, local, normal, position, t

### Community 200 - "AABB"
Cohesion: 0.16
Nodes (9): AABB, .area, .centroid, .isEmpty, BorrowedMesh, MeshGeometry, SIMD2, UInt32 (+1 more)

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - ".build"
Cohesion: 0.16
Nodes (7): .time, UInt64, Data, StaticString, T, UInt, WorldTests

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
Cohesion: 0.14
Nodes (6): OptionSet, Ends, Float, Faces, Bool, .envText

### Community 220 - "Liquids"
Cohesion: 0.11
Nodes (15): Body, muscles, skin, .title, Liquids, all, blood, honey (+7 more)

### Community 221 - "RenderThread"
Cohesion: 0.28
Nodes (3): RenderThread, Thread, Void

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - ".begin"
Cohesion: 0.30
Nodes (4): Snapshot, .isIdle, Stream, LoadActivityTests

### Community 224 - "PlantTracingTests"
Cohesion: 0.36
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 225 - ".addFleshCharacter"
Cohesion: 0.09
Nodes (23): GPUSoftVertex, .cells, Flesh, MuscleSpec, Side, back, front, out (+15 more)

### Community 226 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTLAccelerationStructureCommandEncoder, MTL4ComputeCommandEncoder, MTLBarrierScope

### Community 227 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 228 - "WindFrame"
Cohesion: 0.43
Nodes (6): PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 229 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "CharacterLibrary"
Cohesion: 0.29
Nodes (6): BlobWriter, CharacterLibrary, .directory, concurrently(), URL, Void

### Community 233 - "RenderPass4"
Cohesion: 0.21
Nodes (5): MTL4RenderCommandEncoder, RenderPass4, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 234 - ".keep"
Cohesion: 0.23
Nodes (4): MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLSize

### Community 235 - "TextureStreamerTests"
Cohesion: 0.29
Nodes (3): .residentLevels, URL, TextureStreamerTests

### Community 236 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "WorldPlace"
Cohesion: 0.33
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "Level"
Cohesion: 0.28
Nodes (6): simd_double4x4, Level, .triangleCount, Part, SIMD2, UInt32

### Community 240 - "Section"
Cohesion: 0.33
Nodes (4): NSColor, NSStackView, Section, NSCoder

### Community 241 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 243 - "VGCutTests"
Cohesion: 0.40
Nodes (5): Result, Error, MTLComputePipelineState, MTLDevice, VGCutTests

### Community 246 - "Placement"
Cohesion: 0.40
Nodes (3): Placement, UInt32, UInt16

### Community 247 - "Backend"
Cohesion: 0.50
Nodes (4): Backend, auto, gpu, .title

## Knowledge Gaps
- **1496 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1491 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2031 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **21 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.slots`, `.simplify`, `SettingsTable`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `LoadingOverlay`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `Mesh`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `.meshes`, `FBXFile`, `DebugPanel`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `.build`, `VirtualTracing`, `CityPlan`, `FluidSystem`, `Metal3Pass`, `VoxelGrids`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `Double`, `Float`, `CaseIterable`, `ProceduralTextures`, `Upscaler`, `FluidTests`, `.length`, `MeshBuilder`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `Species`, `.write`, `WorldTile`, `BuildingAssembler`, `Float`, `Key`, `Foliage`, `Config`, `PlantTracing`, `CityTests`, `SDFShape`, `SettingsTableTests`, `SurfaceKind`, `RasterClusters`, `VirtualBLAS`, `XCTestCase`, `Benchmark`, `.init`, `Images`, `VoxelLOD`, `RendererController`, `.draw`, `LayerSurface`, `.buildStress`, `Pipelines`, `LightKind`, `DirectLightMode`, `Phyllotaxis`, `CameraTrack`, `.part`, `VirtualMesh`, `TileAllocator`, `MeshSDFBuilderTests`, `.writeDescriptors`, `RasterScene`, `.stages`, `Int32`, `SceneSettings`, `FoliageRuntimeTests`, `SIMD3`, `HairTests`, `.addRagdoll`, `LumenCards`, `.addHair`, `AABB`, `RagdollTests`, `.build`, `SkyImage`, `Buffer`, `Terrain`, `Bool`, `Liquids`, `.begin`, `PlantTracingTests`, `.addFleshCharacter`, `.encoder`, `WindFrame`, `.commit`, `CharacterLibrary`, `RenderPass4`, `.keep`, `TextureStreamerTests`, `WorldPlace`, `Level`, `StressSceneTests`, `Backend`, `.torusKnotMesh`, `Flora`?**
  _High betweenness centrality (0.369) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `traceKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `FramePlan`, `Pipelines`, `Kernel`, `reflectionKernel`?**
  _High betweenness centrality (0.145) - this node is a cross-community bridge._
- **Why does `Kernel` connect `Kernel` to `String`, `VSMTargets`, `FramePlan`, `Int`, `KernelVariants`, `.draw`, `QuartzCore`, `Key`, `CaseIterable`, `Pipelines`, `Renderer`?**
  _High betweenness centrality (0.133) - this node is a cross-community bridge._
- **Are the 37 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 37 INFERRED edges - model-reasoned connections that need verification._
- **Are the 25 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 25 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `PhysicsWorld` (e.g. with `GPUPhysicsGrab` and `.encodeHairCurves()`) actually correct?**
  _`PhysicsWorld` has 36 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 7 INFERRED edges - model-reasoned connections that need verification._