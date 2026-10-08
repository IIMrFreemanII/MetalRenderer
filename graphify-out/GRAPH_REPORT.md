# Graph Report - init-branch-7e8495  (2026-10-08)

## Corpus Check
- 238 files · ~1,251,603 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6907 nodes · 21254 edges · 241 communities (223 shown, 18 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3180 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `7bbeb898`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- traceKernel
- PlantStore
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- RenderView
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- SDFVolume
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- TextureStreamer
- VGStreamer
- LightSampling.metal
- SkinnedCharacter
- geometryDebugKernel
- Kernel
- SettingsPanel
- Renderer
- Instance
- regirBuildKernel
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
- PlantParam
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- .meshes
- FBXFile
- RendererController
- SceneKind
- 3D Geometric Test Scene
- .xyz
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- SkyParams
- Surface.metal
- VGBlas
- Types.metal
- Direct Rendering Stress Test 32
- MeshSDF
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- CityPlan
- PhysicsWorld
- simd
- Metal3Pass
- FoliageVoxels
- .init
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- VirtualBLAS
- FluidSystem
- World
- Capabilities
- Float
- FoliageTextures
- SurfaceKind
- SceneSettings
- Map
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
- Bool
- Config
- RasterClusters
- EnvVariable
- Int32
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- AABB
- .library
- Foliage
- same.sh
- Key
- baseline.sh
- PlantTracing
- CityTests
- SDFShape
- Raster.metal
- SettingsTableTests
- Slot
- lumenCardRadiosityKernel
- TraversalStats
- PlantWind
- PlantEditorTests
- CharacterRig
- Benchmark
- Shape
- Images
- VoxelLOD
- .write
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- .vgdebug
- .draw
- .writeDescriptors
- VSMCounters
- Camera
- Hit
- QuartzCore
- .buildStress
- Pipelines
- Habitat
- Curve
- .build
- .writeFrameData
- Stage
- CharacterLibrary
- FBXReader.swift
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- Int
- RTVoxels
- Post.metal
- VGParams
- Proving a refactor changed nothing
- .add
- FBXError
- VSM.metal
- FBXTests
- String
- device
- VSMView
- .roof
- VSMClusterArgs
- VSMScene
- PlantSpecies.swift
- TextureStreamerTests
- KernelVariantsTests
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- .int
- Clip
- .buildGallery
- VSMInstance
- SettingsStore
- .addHair
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- uint
- WindFrame
- RagdollTests
- LightKind
- .load
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
- Hair.metal
- .capture
- VoxelGrids
- PhysicsSkinAttach
- Particles
- To do on the M4 Max
- LumenRadiosityParams
- InstanceData
- .withUnsafeBufferPointer
- Measuring MetalRenderer
- Key
- HairBSDF
- .commit
- CharacterImporter
- .runTest
- RenderPass4
- Double
- WorldPlace
- CameraTrack
- .mark
- .useResource
- VirtualGeometry

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 412 edges
2. `Scene` - 306 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 261 edges
5. `Kernel` - 154 edges
6. `Foliage` - 151 edges
7. `.length` - 146 edges
8. `SIMD4` - 142 edges
9. `simd` - 121 edges
10. `Benchmark` - 111 edges

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

## Communities (241 total, 18 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (43): GPUEmissiveTriangle, .viewNote, BorrowedLight, CityLight, CurveMesh, Float, LeafMaterial, LightMotion (+35 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.08
Nodes (48): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+40 more)

### Community 3 - "RenderSettings"
Cohesion: 0.13
Nodes (42): Bound, Codable, Equatable, Cover, UInt32, UInt64, AgeRule, Ages (+34 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (73): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+65 more)

### Community 5 - "traceKernel"
Cohesion: 0.05
Nodes (79): 3. Occupancy and registers: the default suspect for big kernels, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+71 more)

### Community 6 - "PlantStore"
Cohesion: 0.19
Nodes (6): File, Foliage.SpeciesDef, PlantStore, .folder, Data, URL

### Community 7 - ".simplify"
Cohesion: 0.31
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.07
Nodes (28): Reading the table, ObservableObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty (+20 more)

### Community 11 - "RenderView"
Cohesion: 0.05
Nodes (31): AnyObject, CALayer, CGRect, NSDraggingInfo, NSDragOperation, NSObjectProtocol, FrameOutput, LayerSurface (+23 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.09
Nodes (32): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, MetalKit, ComputeStage, Step, FluidGPU, .summary, Steps (+24 more)

### Community 14 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.07
Nodes (27): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLResidencySet (+19 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (16): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, float4x4, LightPose, Kit (+8 more)

### Community 17 - "SDFVolume"
Cohesion: 0.17
Nodes (7): Float16, simd_double3x3, SDFVolume, .hi, Float, Float, SDFShape

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
Nodes (74): constant, device, float2, float3, float4, kernel, Light, read_write (+66 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.11
Nodes (20): MTLRegion, MTLSparseTextureMappingMode, SparseMapping, MTLBuffer, MTLCommandBuffer, MTLHeap, MTLPixelFormat, MTLSize (+12 more)

### Community 24 - "VGStreamer"
Cohesion: 0.06
Nodes (32): Group, Float, MTLBuffer, MTLDevice, SIMD2, UInt32, UnsafePointer, VGStreamer (+24 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.19
Nodes (15): GPUSkinVertex, Clip, .duration, .loopKeys, Level, .triangleCount, Part, SkinnedCharacter (+7 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): NSControl, NSGridView, NSObject, URL, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (66): 8. Pipelines and resources, SkyImage, Set, GPURegirParams, GPUSkyParams, done, PreparedScene, Renderer (+58 more)

### Community 31 - "Instance"
Cohesion: 0.09
Nodes (15): GPUMesh, UInt64, MTLDevice, Float, Instance, .isGeometry, .isStatic, .moves (+7 more)

### Community 32 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

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
Nodes (34): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJoint, .parent (+26 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.13
Nodes (12): CryptoKit, GeneratedCache, SectionFile, Data, T, UInt32, URL, Void (+4 more)

### Community 39 - "Physics.metal"
Cohesion: 0.12
Nodes (61): constant, device, int3, kernel, uint, physActivate(), physBreeze(), physCell() (+53 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.13
Nodes (19): Card, Plant, Skeleton, LeafAnchor, LeafShape, blade, kite, needle (+11 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.02
Nodes (99): CaseIterable, Role, bush, groundCover, tree, Body, muscles, skin (+91 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (32): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+24 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (37): .empty, RTPart, MTLCommandQueue, MTLDevice, LoadOptions, RendererError, .description, missingFunction (+29 more)

### Community 45 - "PlantParam"
Cohesion: 0.08
Nodes (42): E, L, .body, EditorGroup, ParamRow, .body, ParamRows, .body (+34 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.16
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.07
Nodes (20): NSApplication, NSApplicationDelegate, NSMenuItem, NSWindowDelegate, AppDelegate, Any, Notification, NSWindow (+12 more)

### Community 49 - ".meshes"
Cohesion: 0.12
Nodes (12): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+4 more)

### Community 50 - "FBXFile"
Cohesion: 0.21
Nodes (9): IteratorProtocol, Sequence, Children, Connection, FBXFile, .topLevel, Node, StaticString (+1 more)

### Community 51 - "RendererController"
Cohesion: 0.06
Nodes (25): DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification, NSPanel (+17 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.10
Nodes (14): GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, Float, SIMD8 (+6 more)

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
Nodes (38): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+30 more)

### Community 60 - "SkyParams"
Cohesion: 0.04
Nodes (49): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+41 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (86): Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+78 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "Types.metal"
Cohesion: 0.06
Nodes (35): InstanceBlockRef, records, MaterialTexture, t, MeshData, block, cutout, firstIndex (+27 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "MeshSDF"
Cohesion: 0.22
Nodes (8): Int8, Baked, bricks, MeshSDF, .bytes, .hi, .storedBricks, .data

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.07
Nodes (22): MTLHeap, .instanceAS, .virtualGeometryChanged, MTLResource, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice (+14 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (34): .area, Block, CityPlan, Edge, open, party, street, Lamp (+26 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.10
Nodes (20): GPUFluidParams, GPUFluidParticle, Cloth, PhysicsWorld, .buckets, .cellSize, .kinematicRows, .params (+12 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (18): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+10 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.21
Nodes (12): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32, BoxData (+4 more)

### Community 78 - ".init"
Cohesion: 0.24
Nodes (7): LoadStep, Entry, Level, Data, MTLCommandQueue, MTLDevice, URL

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.20
Nodes (15): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+7 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.06
Nodes (30): NSFont, NSPoint, NSView, Sendable, Job, .heading, LoadActivity, .onChange (+22 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.07
Nodes (37): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+29 more)

### Community 86 - "FluidSystem"
Cohesion: 0.09
Nodes (27): .surfaceCapacity, Float, UInt32, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims (+19 more)

### Community 87 - "World"
Cohesion: 0.14
Nodes (16): World, .anchorTile, .start, Block, City, Ground, Placement, Road (+8 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Float"
Cohesion: 0.12
Nodes (22): Level, Mesh, Float, Bone, Card, Carve, Graft, Grower (+14 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (23): heights, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness (+15 more)

### Community 92 - "SceneSettings"
Cohesion: 0.07
Nodes (13): SceneSettings, SIMD2, ForestTests, PlantTracingTests, MTLCommandQueue, MTLDevice, PlantWorkshopTests, Void (+5 more)

### Community 93 - "Map"
Cohesion: 0.10
Nodes (17): Map, Float, SIMD2, UpscaleInputs, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture (+9 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.20
Nodes (5): FluidTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.14
Nodes (8): GPUPhysicsGrab, .length, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "MuscleTests"
Cohesion: 0.09
Nodes (12): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, MuscleTests (+4 more)

### Community 99 - "Footprint"
Cohesion: 0.15
Nodes (14): BuildingGenerator, BuildingSpec, BuildingTier, .top, Detail, flat, full, Footprint (+6 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (37): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient() (+29 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.09
Nodes (23): ArraySlice, GPUPhysicsParticle, GPUSoftVertex, .particleCellSize, Flesh, SIMD2, NearCache, SoftModel (+15 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (47): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+39 more)

### Community 104 - "Building"
Cohesion: 0.25
Nodes (7): Building, Module, Data, float4x4, BuildingTests, Float, SIMD2

### Community 105 - "SurfaceMaterial"
Cohesion: 0.09
Nodes (22): Hashable, SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle (+14 more)

### Community 106 - "Bool"
Cohesion: 0.07
Nodes (30): F, MTLInstanceAccelerationStructureDescriptor, .descriptor, Bool, .envText, Control, checkbox, custom (+22 more)

### Community 108 - "RasterClusters"
Cohesion: 0.11
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 110 - "Int32"
Cohesion: 0.15
Nodes (13): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer, .cells, SkinOptions (+5 more)

### Community 111 - "CurveEditor"
Cohesion: 0.22
Nodes (12): CGPoint, DragGesture, CurveEditor, .canvas, .points, .presetTitle, LinearColorPicker, .body (+4 more)

### Community 112 - "WorldTile"
Cohesion: 0.11
Nodes (22): GPUMaterial, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+14 more)

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

### Community 119 - "AABB"
Cohesion: 0.07
Nodes (25): AABB, .area, .centroid, .isEmpty, float4x4, GLTFModel, .bounds, .triangleCount (+17 more)

### Community 120 - ".library"
Cohesion: 0.08
Nodes (17): RawRepresentable, Age, mature, sapling, young, Species, .description, .hasBoughs (+9 more)

### Community 121 - "Foliage"
Cohesion: 0.08
Nodes (20): Foliage, Phyllotaxis, distichous, spiral, whorled, T, Flora, .geometry (+12 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.14
Nodes (11): CodingKey, Foliage.Curve, Key, crown, linear, points, taper, Decoder (+3 more)

### Community 125 - "PlantTracing"
Cohesion: 0.18
Nodes (14): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+6 more)

### Community 127 - "SDFShape"
Cohesion: 0.06
Nodes (41): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+33 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.15
Nodes (3): Settings: `SettingsTable.swift`, SettingsEnv, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "TraversalStats"
Cohesion: 0.19
Nodes (8): DebugInfo, Float, RendererStatus, UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.11
Nodes (8): PlantMutate, Root, SplitMix64, Host, PlantEditorTests, Root, URL, Void

### Community 135 - "CharacterRig"
Cohesion: 0.15
Nodes (14): FleshOptions, MuscleSpec, Side, back, front, out, Bone, CharacterRig (+6 more)

### Community 136 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 138 - "Images"
Cohesion: 0.15
Nodes (3): 6. Math, Modes, Images

### Community 139 - "VoxelLOD"
Cohesion: 0.16
Nodes (14): .megabytes, Entry, Float, float4x4, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue (+6 more)

### Community 140 - ".write"
Cohesion: 0.17
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (19): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device (+11 more)

### Community 144 - ".vgdebug"
Cohesion: 0.14
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 145 - ".draw"
Cohesion: 0.16
Nodes (13): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, The pass, The pass after a feature (+5 more)

### Community 146 - ".writeDescriptors"
Cohesion: 0.27
Nodes (6): Tests, float3x3, Float, float4x4, UInt32, Wind

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "Camera"
Cohesion: 0.17
Nodes (11): Darwin, Camera, .forward, .right, .up, .worldToView, rotate(), Float (+3 more)

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (6): Combine, Element, MetalFX, QuartzCore, Array, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (23): Parts, .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Float (+15 more)

### Community 152 - "Pipelines"
Cohesion: 0.07
Nodes (34): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, Things that are not structures yet, Where new code belongs, MTL4InstanceAccelerationStructureDescriptor, ComputePass, FrameEncoder, PrimitiveRefit, PrimitiveWork (+26 more)

### Community 153 - "Habitat"
Cohesion: 0.36
Nodes (6): Habitat, Ramp, Float, SIMD2, TreePicker, .isEmpty

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - ".build"
Cohesion: 0.14
Nodes (11): Heightfield, .hi, MeshSDFBuilder, Float, SIMD2, UInt32, UnsafeBufferPointer, MeshSDFBuilderTests (+3 more)

### Community 156 - ".writeFrameData"
Cohesion: 0.16
Nodes (9): CrowdSkinner, PoseParams, SkinParams, MTLBuffer, MTLDevice, UInt32, Float, UnsafeBufferPointer (+1 more)

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "CharacterLibrary"
Cohesion: 0.29
Nodes (6): BlobWriter, CharacterLibrary, .directory, concurrently(), URL, Void

### Community 159 - "FBXReader.swift"
Cohesion: 0.19
Nodes (9): Compression, Contents, FBXArrayElement, unsupported, Float, Int64, MappedFile, UnsafeRawPointer (+1 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "AppKit"
Cohesion: 0.16
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "Int"
Cohesion: 0.05
Nodes (38): GPUFogParams, .reflectionPassFlags, GPUPostParams, Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float (+30 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): constant, device, float4, float4x4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "Proving a refactor changed nothing"
Cohesion: 0.21
Nodes (5): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Timings, What could not be run

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - "FBXError"
Cohesion: 0.33
Nodes (6): FBXError, .description, BlobReader, Data, StaticString, T

### Community 172 - "VSM.metal"
Cohesion: 0.24
Nodes (16): float4, float4x4, fragment, thread, uint2, vertex, vsmBoxPages(), vsmClearVertex() (+8 more)

### Community 174 - "String"
Cohesion: 0.05
Nodes (35): MTLBlitCommandEncoder, MTLCommandEncoder, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassDescriptor, MTLTimestamp, NSColor (+27 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".roof"
Cohesion: 0.31
Nodes (4): OptionSet, Ends, Float, Faces

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 181 - "TextureStreamerTests"
Cohesion: 0.29
Nodes (3): .residentLevels, URL, TextureStreamerTests

### Community 182 - "KernelVariantsTests"
Cohesion: 0.22
Nodes (5): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.07
Nodes (28): Atmosphere, Float, GPUHairGroup, GPUPhysicsShape, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold (+20 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".int"
Cohesion: 0.53
Nodes (3): invalid, T, UnsafeRawBufferPointer

### Community 189 - "Clip"
Cohesion: 0.23
Nodes (8): .body, Clip, graft, habitat, leaves, level, look, Clipboard

### Community 190 - ".buildGallery"
Cohesion: 0.14
Nodes (4): SplitMix64, MeshGeometry, UInt64, SDFTests

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "SettingsStore"
Cohesion: 0.22
Nodes (4): base, SettingsStore, Any, DispatchWorkItem

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

### Community 199 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 200 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 201 - "RagdollTests"
Cohesion: 0.16
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "LightKind"
Cohesion: 0.22
Nodes (9): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+1 more)

### Community 203 - ".load"
Cohesion: 0.11
Nodes (13): CustomStringConvertible, Error, LoadError, unreadable, GLTFError, .description, Failure, ShaderSource (+5 more)

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 206 - "Buffer"
Cohesion: 0.22
Nodes (8): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLHeap, UInt64

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

### Community 219 - "Hair.metal"
Cohesion: 0.10
Nodes (39): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+31 more)

### Community 220 - ".capture"
Cohesion: 0.29
Nodes (4): MTLBuffer, MTLDevice, MTLTexture, Void

### Community 221 - "VoxelGrids"
Cohesion: 0.29
Nodes (6): MTLResource, MTLAccelerationStructure, MTLBuffer, VoxelGrids, .buffers, .megabytes

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 223 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 224 - "To do on the M4 Max"
Cohesion: 0.50
Nodes (3): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max

### Community 225 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 226 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 227 - ".withUnsafeBufferPointer"
Cohesion: 0.20
Nodes (6): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), R, Hasher, .array, UnsafeBufferPointer, UnsafeRawBufferPointer

### Community 228 - "Measuring MetalRenderer"
Cohesion: 0.40
Nodes (5): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding

### Community 229 - "Key"
Cohesion: 0.24
Nodes (6): Key, PipelineCache, .count, PipelineCacheTests, UInt32, Value

### Community 231 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "CharacterImporter"
Cohesion: 0.22
Nodes (10): simd_double4x4, simd_quatd, CharacterImporter, Mapping, controlPoint, polygonVertex, Skeleton, .bindPositions (+2 more)

### Community 234 - "RenderPass4"
Cohesion: 0.18
Nodes (6): MTL4RenderCommandEncoder, RenderPass4, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 236 - "Double"
Cohesion: 0.14
Nodes (11): Float, Double, Flora, Heavens, .adaptation, .light, .lightIsMoon, .stars (+3 more)

### Community 237 - "WorldPlace"
Cohesion: 0.43
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 241 - "CameraTrack"
Cohesion: 0.13
Nodes (7): CameraTrack, .duration, Key, Float, ShowcaseLook, Float, Void

### Community 248 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

## Knowledge Gaps
- **1541 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1536 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2111 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **18 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.simplify`, `PlantEditorModel`, `RenderView`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `TextureStreamer`, `VGStreamer`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Instance`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `.write`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `PlantParam`, `LumenScene`, `.meshes`, `FBXFile`, `RendererController`, `SceneKind`, `.xyz`, `MuscleAtlas`, `MeshSDF`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `Metal3Pass`, `FoliageVoxels`, `.init`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `FluidSystem`, `World`, `Float`, `FoliageTextures`, `SurfaceKind`, `SceneSettings`, `Map`, `FluidTests`, `.length`, `MuscleTests`, `Footprint`, `SoftModel`, `Building`, `Bool`, `Config`, `RasterClusters`, `EnvVariable`, `Int32`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `AABB`, `.library`, `Foliage`, `PlantTracing`, `CityTests`, `SDFShape`, `Slot`, `TraversalStats`, `CharacterRig`, `Benchmark`, `Images`, `VoxelLOD`, `.write`, `.writeDescriptors`, `QuartzCore`, `.buildStress`, `Pipelines`, `Curve`, `.build`, `.writeFrameData`, `CharacterLibrary`, `FBXReader.swift`, `FBXError`, `FBXTests`, `String`, `.roof`, `TextureStreamerTests`, `FoliageRuntimeTests`, `SIMD3`, `.int`, `.buildGallery`, `.addHair`, `WindFrame`, `RagdollTests`, `LightKind`, `Terrain`, `VoxelGrids`, `Key`, `.commit`, `CharacterImporter`, `.runTest`, `RenderPass4`, `Double`, `WorldPlace`, `VirtualGeometry`?**
  _High betweenness centrality (0.324) - this node is a cross-community bridge._
- **Why does `Kernel` connect `Kernel` to `Measuring MetalRenderer`, `Int`, `Key`, `SettingsTable.swift`, `VSMTargets`, `FramePlan`, `String`, `KernelVariants`, `QuartzCore`, `Renderer`?**
  _High betweenness centrality (0.125) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `VoxelLOD`, `.write`, `FluidSurface.metal`, `.buildStress`, `Pipelines`, `TextureStreamer`, `SkinnedCharacter`, `VGStreamer`, `Renderer`, `TraceScene`, `SectionFile`, `SceneBuffers`, `KernelVariantsTests`, `MuscleAtlas`, `VirtualTracing`, `CityPlan`, `.load`, `Terrain`, `LoadActivity`, `VirtualBLAS`, `Capabilities`, `SurfaceKind`, `VoxelGrids`, `Key`, `RasterClusters`, `PlantTracing`?**
  _High betweenness centrality (0.120) - this node is a cross-community bridge._
- **Are the 39 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 39 INFERRED edges - model-reasoned connections that need verification._
- **Are the 27 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 27 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1541 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.04408749145591251 - nodes in this community are weakly interconnected._