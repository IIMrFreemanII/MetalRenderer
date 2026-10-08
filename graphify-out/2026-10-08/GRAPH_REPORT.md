# Graph Report - init-branch-94ae07  (2026-10-08)

## Corpus Check
- 230 files · ~1,270,312 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6994 nodes · 21457 edges · 242 communities (219 shown, 23 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3292 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `47be591a`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- ParticleTrace.metal
- Hair.metal
- .simplify
- Fluid.metal
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- Metal3Frame
- Metal4Frame
- translate
- ParticleEmitter
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VirtualGeometry
- LightSampling.metal
- SkinnedCharacter
- .planFrame
- Kernel
- SettingsPanel
- Renderer
- Build
- traceKernel
- restirSpatialKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- SectionFile
- Physics.metal
- Uniforms
- .write
- String
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- DebugPanel
- Crowd
- FBXFile
- RendererController
- SceneKind
- 3D Geometric Test Scene
- ParticleMath
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- Types.metal
- Shaders.metal
- SDFBox
- MeshData
- Direct Rendering Stress Test 32
- .build
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- Int
- CityPlan
- SIMD3
- simd
- RenderPass
- VGStreamer
- SDFShape
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- uint
- VirtualBLAS
- GLTFModel
- Double
- Capabilities
- Float
- FoliageTextures
- SurfaceKind
- ParticleTextures
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- quatRotate
- .length
- MuscleTests
- Footprint
- float3
- ClusterBox
- SoftModel
- uint4
- Building
- BuildingStyle
- EnvVariable
- ParticleSystem
- .load
- Benchmark
- Species
- .write
- GPUMaterial
- compositeKernel
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- .init
- HairTests
- Foliage
- same.sh
- Physics.swift
- baseline.sh
- PlantTracing
- CityTests
- Camera
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- StressSceneTests
- ParticleEmitter
- WindFrame
- FrameEncoder
- SIMD4
- VoxelLOD
- VirtualMesh
- FluidSurface.metal
- RasterClusters.metal
- .writeDescriptors
- Bool
- .draw
- LayerSurface
- VSMCounters
- Particles.metal
- LumenMeshSDF
- QuartzCore
- .buildStress
- Pipelines
- .kind
- Crown
- CharacterImporter
- Phyllotaxis
- Stage
- FBXError
- FBXReader.swift
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- SkyImage
- RTVoxels
- CharacterLibrary
- VGParams
- float3
- .galleryFiles
- FoliageRuntimeTests
- VSM.metal
- dot
- .addHair
- RendererError
- VSMView
- .int
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- SceneShading
- .addMesh
- SkyParams
- VSMParams
- VoxelGrids
- PhysicsWorld
- RasterParams
- Lumen
- XCTestCase
- ParticleCounts
- VSMInstance
- LumenSDFHit
- .render
- PhysicsJoint
- RasterCounters
- ParticleTrailPose
- ParticleLayerParams
- SettingsStore
- .torusKnotMesh
- .scaled
- .setRenderPipelineState
- WorldTile
- GPUProfiler
- PhysicsGrab
- PhysPush
- Buffer
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- float4
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- ParticleStep
- .init
- RasterScene
- PhysicsSkinAttach
- LightKind
- FleshFigure
- .encoder
- .capture
- Map
- HairBSDF
- .commit
- .updatePrimitives
- RenderPass4
- Float
- WorldPlace
- SplitMix64
- boxCandidate
- particleOverlayKernel
- VGBlas
- .mark
- .useResource
- Particles
- LightMotion

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 442 edges
2. `Scene` - 304 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 263 edges
5. `Kernel` - 165 edges
6. `SIMD4` - 161 edges
7. `.length` - 160 edges
8. `simd` - 117 edges
9. `Benchmark` - 112 edges
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

## Communities (242 total, 23 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.06
Nodes (38): AABB, .area, .centroid, .isEmpty, SDFVolume, Assembly, Bone, CityLight (+30 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.16
Nodes (31): Buffer, Decodable, Decoder, Node, Primitive, Accessor, AnyDecodable, Asset (+23 more)

### Community 3 - "RenderSettings"
Cohesion: 0.10
Nodes (35): Codable, Equatable, ParticleEmitter, Void, CascadeSettings, CitySettings, ClosedRange, DenoiserSettings (+27 more)

### Community 4 - "Lights.metal"
Cohesion: 0.06
Nodes (86): clipSegment(), ggxFromDirection(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular(), LightSubset (+78 more)

### Community 5 - "ParticleTrace.metal"
Cohesion: 0.08
Nodes (58): half4, float2, float3, float4, primitive_acceleration_structure, read, SCENE_ACCEL, texture2d (+50 more)

### Community 6 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

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
Cohesion: 0.07
Nodes (30): Bound, F, on, .reservoirCount, Control, checkbox, custom, popup (+22 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView (+10 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.14
Nodes (28): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+20 more)

### Community 13 - "FramePlan"
Cohesion: 0.21
Nodes (11): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+3 more)

### Community 14 - "Metal3Frame"
Cohesion: 0.20
Nodes (7): Metal3Frame, CAMetalDrawable, MTLCommandBuffer, MTLCommandQueue, MTLComputeCommandEncoder, UInt32, Void

### Community 15 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 16 - "translate"
Cohesion: 0.19
Nodes (13): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+5 more)

### Community 17 - "ParticleEmitter"
Cohesion: 0.10
Nodes (20): Flags, Orientation, axis, .code, rayFacing, velocity, world, ParticleEmitter (+12 more)

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
Cohesion: 0.04
Nodes (94): Where things are, distance, makeRay(), liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial() (+86 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.07
Nodes (29): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLBuffer, MTLCommandBuffer (+21 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.09
Nodes (23): SIMD2, UnsafePointer, Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer (+15 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.16
Nodes (12): GPUJoint, GPUJointMatrix, Clip, .duration, .loopKeys, SkinnedCharacter, .bindPoses, .triangleCount (+4 more)

### Community 27 - ".planFrame"
Cohesion: 0.07
Nodes (20): MetalKit, GPUPostParams, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets, LiquidTargets, LoadOptions (+12 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (146): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+138 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): Settings: `SettingsTable.swift`, NSControl, NSGridView, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (54): 8. Pipelines and resources, done, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode, .cameraClusters (+46 more)

### Community 31 - "Build"
Cohesion: 0.10
Nodes (17): Particles: handoff (branch claude/init-branch-94ae07), To do on the M4 Max, Traps found, PrimitiveWork4, MTL4ComputeCommandEncoder, MTLAllocation, Build, Part (+9 more)

### Community 32 - "traceKernel"
Cohesion: 0.09
Nodes (45): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), float4, cosineSampleHemisphere(), laineKarrasPermutation(), luminance(), makeSampler(), constant (+37 more)

### Community 33 - "restirSpatialKernel"
Cohesion: 0.10
Nodes (39): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, emptyReservoir(), constant (+31 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.09
Nodes (37): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUInstanceData (+29 more)

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

### Community 41 - ".write"
Cohesion: 0.15
Nodes (18): Card, Plant, Skeleton, LeafShape, blade, kite, needle, Mesh (+10 more)

### Community 42 - "String"
Cohesion: 0.03
Nodes (94): CaseIterable, Body, muscles, skin, .title, CityStyle, mixed, modern (+86 more)

### Community 43 - "VSMTargets"
Cohesion: 0.06
Nodes (34): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+26 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (33): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, InstanceBlock, .held, MeshBlock (+25 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.15
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "DebugPanel"
Cohesion: 0.04
Nodes (33): NSApplication, NSApplicationDelegate, NSColor, NSMenuItem, NSObject, NSStackView, NSWindowDelegate, DebugPanel (+25 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "FBXFile"
Cohesion: 0.20
Nodes (10): IteratorProtocol, Sequence, Children, Connection, FBXFile, .topLevel, Node, StaticString (+2 more)

### Community 51 - "RendererController"
Cohesion: 0.09
Nodes (16): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles, RendererController (+8 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (38): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+30 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "ParticleMath"
Cohesion: 0.11
Nodes (16): GPUParticle, GPUParticleCollider, GPUParticleEmitter, GPUParticleField, GPUParticleRender, Fragment, ParticleEvent, .seed (+8 more)

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

### Community 60 - "Types.metal"
Cohesion: 0.06
Nodes (41): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+33 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (101): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+93 more)

### Community 62 - "SDFBox"
Cohesion: 0.10
Nodes (21): device, SDFBox, pad0, pad1, pad2, pad3, scene, shape (+13 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - ".build"
Cohesion: 0.09
Nodes (20): Int8, float4x4, Baked, bricks, Heightfield, .hi, MeshSDF, .bytes (+12 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "Int"
Cohesion: 0.04
Nodes (51): MTL4InstanceAccelerationStructureDescriptor, PrimitiveRefit, PrimitiveWork, .encoderCount, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLInstanceAccelerationStructureDescriptor, MTLPrimitiveAccelerationStructureDescriptor (+43 more)

### Community 73 - "CityPlan"
Cohesion: 0.11
Nodes (25): Block, CityPlan, Edge, open, party, street, Lamp, Lot (+17 more)

### Community 74 - "SIMD3"
Cohesion: 0.07
Nodes (30): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, GPURasterMesh (+22 more)

### Community 76 - "RenderPass"
Cohesion: 0.11
Nodes (7): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, UnsafeRawPointer

### Community 77 - "VGStreamer"
Cohesion: 0.06
Nodes (31): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+23 more)

### Community 78 - "SDFShape"
Cohesion: 0.12
Nodes (23): Node, .transform, Op, intersect, subtract, union, Primitive, box (+15 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.14
Nodes (14): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+6 more)

### Community 80 - "KernelVariants"
Cohesion: 0.15
Nodes (19): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Key (+11 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.05
Nodes (35): NSFont, NSPoint, NSView, Sendable, Job, .heading, LoadActivity, .onChange (+27 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.20
Nodes (27): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+19 more)

### Community 84 - "uint"
Cohesion: 0.12
Nodes (34): candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart() (+26 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.14
Nodes (21): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+13 more)

### Community 86 - "GLTFModel"
Cohesion: 0.11
Nodes (20): invalid, unsupported, GLTFModel, .bounds, .triangleCount, Image, Kind, directional (+12 more)

### Community 87 - "Double"
Cohesion: 0.13
Nodes (15): Float, Double, World, .anchorTile, .start, City, Flora, Ground (+7 more)

### Community 88 - "Capabilities"
Cohesion: 0.24
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.15
Nodes (14): Card, Carve, Graft, Grower, LeafAnchor, LeafRecipe, Level, Recipe (+6 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (23): heights, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness (+15 more)

### Community 92 - "ParticleTextures"
Cohesion: 0.10
Nodes (25): Kind, .flags, Aux, flameMotion, .layer, smokeBack, smokeLight, Kind (+17 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (54): groupElement(), uint4, cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi (+46 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (21): Metal3Pass, .declarationScope, AnyObject, FluidWorld, LiquidKind, blood, honey, .look (+13 more)

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.13
Nodes (10): GPUPhysicsGrab, Cloth, Set, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice (+2 more)

### Community 98 - "MuscleTests"
Cohesion: 0.15
Nodes (5): MuscleTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 99 - "Footprint"
Cohesion: 0.12
Nodes (19): BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint, .area (+11 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (22): ArraySlice, GPUPhysicsParticle, GPUSoftEmbed, GPUSoftVertex, .particleCellSize, NearCache, SoftModel, .near (+14 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.16
Nodes (11): Building, .triangleCount, BuildingGenerator, Module, SurfaceMaterial, .uvScale, Data, float4x4 (+3 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (19): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+11 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 107 - "ParticleSystem"
Cohesion: 0.06
Nodes (38): Built, Hashable, Part, ParticleCollider, box, .gpu, plane, shape (+30 more)

### Community 108 - ".load"
Cohesion: 0.15
Nodes (10): CustomStringConvertible, Error, GLTFError, .description, Failure, ShaderSource, URL, Substring (+2 more)

### Community 109 - "Benchmark"
Cohesion: 0.04
Nodes (33): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+25 more)

### Community 110 - "Species"
Cohesion: 0.09
Nodes (22): Mesh, Age, mature, sapling, young, Bone, Part, Plant (+14 more)

### Community 111 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 112 - "GPUMaterial"
Cohesion: 0.28
Nodes (8): GPUMaterial, Assembler, Draft, Data, float4x4, SIMD2, UInt8, Void

### Community 113 - "compositeKernel"
Cohesion: 0.05
Nodes (85): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+77 more)

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
Cohesion: 0.14
Nodes (36): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams, grid, options (+28 more)

### Community 119 - ".init"
Cohesion: 0.09
Nodes (19): GPUEmissiveTriangle, BorrowedLight, BorrowedMesh, Instance, .isGeometry, .isStatic, .moves, InstanceGroup (+11 more)

### Community 120 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 121 - "Foliage"
Cohesion: 0.14
Nodes (15): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+7 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Physics.swift"
Cohesion: 0.33
Nodes (4): PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 125 - "PlantTracing"
Cohesion: 0.15
Nodes (15): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+7 more)

### Community 127 - "Camera"
Cohesion: 0.14
Nodes (12): Darwin, Camera, .forward, .right, .up, rotate(), Float, float4x4 (+4 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (43): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+35 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.12
Nodes (7): SkyMode, atmosphere, constant, image, .title, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (49): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+41 more)

### Community 132 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 135 - "ParticleEmitter"
Cohesion: 0.09
Nodes (23): ParticleEmitter, attractor, axis, burst, color0, color1, color2, extent (+15 more)

### Community 136 - "WindFrame"
Cohesion: 0.15
Nodes (10): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey, PlantTracingTests (+2 more)

### Community 137 - "FrameEncoder"
Cohesion: 0.14
Nodes (8): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameEncoder, RenderAttachments, MTLSize, MTLTexture, Range, .instanceDataBuffers, MTLResource

### Community 138 - "SIMD4"
Cohesion: 0.08
Nodes (22): GPUPhysicsShape, Float, float4x4, SDFShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath (+14 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - "VirtualMesh"
Cohesion: 0.14
Nodes (16): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+8 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.11
Nodes (35): RasterClusterMeshOut, constant, device, float4, kernel, read, texture2d, thread (+27 more)

### Community 143 - ".writeDescriptors"
Cohesion: 0.25
Nodes (7): Tests, RTPart, Float, float3x3, float4x4, UInt32, Wind

### Community 144 - "Bool"
Cohesion: 0.20
Nodes (4): Ends, Float, Bool, .envText

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (27): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants, Launch time (+19 more)

### Community 146 - "LayerSurface"
Cohesion: 0.15
Nodes (15): CGSize, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title (+7 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Particles.metal"
Cohesion: 0.30
Nodes (21): constant, device, float4x4, kernel, uint, particleBeginKernel(), particleChildSeed(), particleColor() (+13 more)

### Community 149 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 150 - "QuartzCore"
Cohesion: 0.18
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (24): OptionSet, Parts, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+16 more)

### Community 152 - "Pipelines"
Cohesion: 0.06
Nodes (37): ComputePass, MTLBarrierScope, MTLComputePipelineState, MTLHeap, MTLResource, MTLResourceUsage, MTLComputePipelineState, Step (+29 more)

### Community 154 - "Crown"
Cohesion: 0.29
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "CharacterImporter"
Cohesion: 0.18
Nodes (12): simd_double4x4, simd_quatd, CharacterImporter, Level, .triangleCount, Part, Skeleton, .bindPositions (+4 more)

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "FBXError"
Cohesion: 0.24
Nodes (9): FBXError, .description, BlobReader, Mapping, controlPoint, polygonVertex, Data, StaticString (+1 more)

### Community 159 - "FBXReader.swift"
Cohesion: 0.19
Nodes (9): Compression, Contents, FBXArrayElement, unsupported, Float, Int64, MappedFile, UnsafeRawPointer (+1 more)

### Community 160 - "TraceScene"
Cohesion: 0.06
Nodes (34): instance_acceleration_structure, RTPart, primitive_acceleration_structure, texture2d_array, uint2, TraceScene, clusterInstance, clusters (+26 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.18
Nodes (21): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit() (+13 more)

### Community 162 - "AppKit"
Cohesion: 0.19
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.20
Nodes (10): RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad, requestCapacity (+2 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "SkyImage"
Cohesion: 0.25
Nodes (7): Atmosphere, LoadError, unreadable, SkyImage, Float, Set, URL

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "CharacterLibrary"
Cohesion: 0.29
Nodes (6): BlobWriter, CharacterLibrary, .directory, concurrently(), URL, Void

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "float3"
Cohesion: 0.38
Nodes (7): float3, float3x3, int3, particleCurl(), particleGradient(), particleNoise(), particleTurn()

### Community 172 - "VSM.metal"
Cohesion: 0.16
Nodes (41): constant, device, float3, float4, float4x4, fragment, kernel, Light (+33 more)

### Community 173 - "dot"
Cohesion: 0.07
Nodes (19): Float16, simd_double3x3, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, .worldToView, dot (+11 more)

### Community 174 - ".addHair"
Cohesion: 0.10
Nodes (12): GPUMesh, UInt64, CurveMesh, HairStyle, Float, UInt32, SplitMix, Float (+4 more)

### Community 175 - "RendererError"
Cohesion: 0.27
Nodes (7): MTLDevice, MTLCommandQueue, MTLDevice, RendererError, .description, missingFunction, unsupported

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".int"
Cohesion: 0.53
Nodes (3): invalid, T, UnsafeRawBufferPointer

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 181 - "SceneShading"
Cohesion: 0.12
Nodes (16): MaterialTexture, t, texture2d, texture2d_array, SceneShading, cloudShadow, emissive, feedback (+8 more)

### Community 182 - ".addMesh"
Cohesion: 0.15
Nodes (6): MeshGeometry, UInt32, MeshGeometry, Float, MeshGeometry, Void

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
Nodes (27): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsJoint, GPUPhysicsParams, PhysicsWorld, .cellSize, .kinematicRows, .params (+19 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Lumen"
Cohesion: 0.25
Nodes (8): Lumen, LumenParams, LumenRadiosityParams, Float, MTLBuffer, MTLTexture, SIMD2, UInt32

### Community 189 - "XCTestCase"
Cohesion: 0.24
Nodes (5): CacheTests, URL, PipelineCacheTests, UInt32, XCTestCase

### Community 190 - "ParticleCounts"
Cohesion: 0.15
Nodes (13): atomic_uint, ParticleCounts, alive, dead, deadTop, emitBase, emitCount, emitFirst (+5 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "LumenSDFHit"
Cohesion: 0.29
Nodes (7): LumenSDFHit, hit, id, local, normal, position, t

### Community 194 - "PhysicsJoint"
Cohesion: 0.25
Nodes (8): PhysicsJoint, anchorA, anchorB, axisA, axisB, info, referenceA, referenceB

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "ParticleTrailPose"
Cohesion: 0.33
Nodes (6): ParticleTrailPose, camera, emitters, points, step, trails

### Community 197 - "ParticleLayerParams"
Cohesion: 0.50
Nodes (4): ParticleLayerParams, detail, jitter, size

### Community 198 - "SettingsStore"
Cohesion: 0.22
Nodes (4): DispatchWorkItem, base, SettingsStore, Any

### Community 202 - "WorldTile"
Cohesion: 0.12
Nodes (16): .time, Chunk, .triangles, ChunkRecord, Light, Float, UInt32, UInt64 (+8 more)

### Community 203 - "GPUProfiler"
Cohesion: 0.09
Nodes (16): MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassDescriptor, MTLTimestamp, Frame (+8 more)

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
Cohesion: 0.29
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

### Community 213 - "float4"
Cohesion: 0.12
Nodes (18): float4, uint4, Particle, info, position, velocity, ParticleEvent, a (+10 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "ParticleStep"
Cohesion: 0.11
Nodes (22): thread, particleBasis(), particleCollide(), ParticleCollider, a, b, particleCollideScene(), particleCollideShape() (+14 more)

### Community 221 - "RasterScene"
Cohesion: 0.16
Nodes (12): Kind, arrays, block, clusters, skip, virtual, RasterScene, .megabytes (+4 more)

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 224 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 225 - "FleshFigure"
Cohesion: 0.11
Nodes (19): .cells, Flesh, MuscleSpec, Side, back, front, out, SIMD2 (+11 more)

### Community 226 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 227 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 229 - "Map"
Cohesion: 0.17
Nodes (7): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 231 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".updatePrimitives"
Cohesion: 0.29
Nodes (4): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder

### Community 234 - "RenderPass4"
Cohesion: 0.16
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, UnsafeRawPointer

### Community 236 - "Float"
Cohesion: 0.17
Nodes (11): Block, Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation, Highway (+3 more)

### Community 237 - "WorldPlace"
Cohesion: 0.43
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "SplitMix64"
Cohesion: 0.27
Nodes (5): Shape, box, sphere, SplitMix64, UInt64

### Community 239 - "boxCandidate"
Cohesion: 0.48
Nodes (7): boxCandidate(), clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 240 - "particleOverlayKernel"
Cohesion: 0.30
Nodes (12): float2, read, read_write, SCENE_ACCEL, texture2d, texture3d, uint2, write (+4 more)

### Community 242 - "VGBlas"
Cohesion: 0.29
Nodes (7): VGBlas, attrs, pad0, pad1, pad2, triangles, tris

### Community 246 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 251 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

## Knowledge Gaps
- **1655 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1650 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2223 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **23 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.simplify`, `SettingsTable`, `FramePlan`, `Metal3Frame`, `Metal4Frame`, `translate`, `ParticleEmitter`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `.planFrame`, `Kernel`, `SettingsPanel`, `Renderer`, `Build`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `DebugPanel`, `Crowd`, `FBXFile`, `RendererController`, `SceneKind`, `ParticleMath`, `MuscleAtlas`, `.build`, `CityPlan`, `SIMD3`, `RenderPass`, `VGStreamer`, `SDFShape`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `GLTFModel`, `Double`, `Float`, `FoliageTextures`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `Metal3Pass`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `EnvVariable`, `ParticleSystem`, `Benchmark`, `Species`, `.write`, `GPUMaterial`, `BuildingAssembler`, `.init`, `HairTests`, `Foliage`, `PlantTracing`, `CityTests`, `Camera`, `SettingsTableTests`, `Slot`, `TraversalStats`, `StressSceneTests`, `WindFrame`, `FrameEncoder`, `SIMD4`, `VoxelLOD`, `VirtualMesh`, `.writeDescriptors`, `Bool`, `.draw`, `LayerSurface`, `.buildStress`, `Pipelines`, `CharacterImporter`, `Phyllotaxis`, `FBXError`, `FBXReader.swift`, `SkyImage`, `CharacterLibrary`, `FoliageRuntimeTests`, `dot`, `.addHair`, `RendererError`, `.int`, `LumenGlobalSDF`, `.addMesh`, `VoxelGrids`, `PhysicsWorld`, `Lumen`, `XCTestCase`, `.torusKnotMesh`, `WorldTile`, `GPUProfiler`, `Buffer`, `Terrain`, `.init`, `RasterScene`, `LightKind`, `FleshFigure`, `.encoder`, `.commit`, `.updatePrimitives`, `RenderPass4`, `Float`, `WorldPlace`, `SplitMix64`?**
  _High betweenness centrality (0.330) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `KernelVariants` to `traceKernel`, `restirSpatialKernel`, `Map`, `.draw`, `Pipelines`, `Kernel`?**
  _High betweenness centrality (0.108) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `VoxelLOD`, `VirtualMesh`, `FluidSurface.metal`, `.buildStress`, `Pipelines`, `TextureStreamer`, `SkinnedCharacter`, `Renderer`, `TraceScene`, `SectionFile`, `SceneBuffers`, `ParticleMath`, `VoxelGrids`, `MuscleAtlas`, `Int`, `CityPlan`, `VGStreamer`, `Terrain`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `Capabilities`, `SurfaceKind`, `ParticleTextures`, `Upscaler`, `ParticleSystem`, `.load`, `.write`, `Particles`, `PlantTracing`?**
  _High betweenness centrality (0.103) - this node is a cross-community bridge._
- **Are the 48 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 48 INFERRED edges - model-reasoned connections that need verification._
- **Are the 25 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 25 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `PhysicsWorld` (e.g. with `GPUPhysicsGrab` and `.encodeHairCurves()`) actually correct?**
  _`PhysicsWorld` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1655 weakly-connected nodes found - possible documentation gaps or missing edges._