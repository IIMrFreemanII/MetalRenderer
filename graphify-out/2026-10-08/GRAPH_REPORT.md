# Graph Report - init-branch-7e8495  (2026-10-08)

## Corpus Check
- 238 files · ~1,251,282 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 6911 nodes · 21241 edges · 251 communities (227 shown, 24 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3175 edges (avg confidence: 0.84)
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
- PlantStore
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- RenderView
- rcTraceMergeKernel
- FramePlan
- Frame
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
- String
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- FBXFile
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- .xyz
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
- RendererError
- CityPlan
- SIMD3
- simd
- RenderPass
- FoliageVoxels
- LoadJob
- BVHBuilder
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- VirtualBLAS
- FluidSystem
- Double
- Capabilities
- Foliage
- FoliageTextures
- SurfaceKind
- GPUMesh
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- quatRotate
- .length
- MuscleTests
- BuildingAssembler
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
- Int32
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- Bool
- lumenTraceKernel
- AABB
- .library
- Flora
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
- Float
- Benchmark
- Shape
- .useHeap
- VoxelLOD
- .write
- FluidSurface.metal
- RasterClusters.metal
- reflectionKernel
- GPUMaterial
- .draw
- LayerSurface
- VSMCounters
- LumenMeshSDF
- Hit
- QuartzCore
- .buildStress
- Pipelines
- Species
- Curve
- MeshSDFBuilderTests
- SceneShading
- Stage
- CharacterLibrary
- XCTestCase
- TraceScene
- Intersect.metal
- AppKit
- RasterVGParams
- related.sh
- Int
- RTVoxels
- Post.metal
- VGParams
- SkyParams
- .add
- PostParams
- VSM.metal
- PlantParam
- .encodeSceneUpdate
- device
- VSMView
- .stages
- VSMClusterArgs
- VSMScene
- LumenGlobalSDF
- .encoder
- PlantEditorPanel
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- SIMD4
- RasterParams
- .preset
- Clip
- SceneSettings
- VSMInstance
- SettingsStore
- PhysicsSettings
- PhysicsJoint
- RasterCounters
- uint
- LumenParams
- SDFBox
- uint
- InputHandler
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
- .generate
- ShadingPoint
- float4
- RenderThread
- PhysicsSkinAttach
- .begin
- PrimitiveWork
- LumenRadiosityParams
- InstanceData
- .withUnsafeBufferPointer
- .workshop
- Map
- HairBSDF
- .commit
- .part
- LumenSDFHit
- RenderPass4
- PlantEditorModel.swift
- Float
- WorldPlace
- .end
- Types.metal
- StressSceneTests
- CameraTrack
- .setBytes
- Section
- .mark
- .useResource
- Detail
- .kind
- VirtualGeometry
- .init
- .setComputePipelineState

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 412 edges
2. `Scene` - 306 edges
3. `PhysicsWorld` - 272 edges
4. `Renderer` - 261 edges
5. `Kernel` - 154 edges
6. `Foliage` - 148 edges
7. `.length` - 146 edges
8. `SIMD4` - 142 edges
9. `simd` - 121 edges
10. `Benchmark` - 111 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift
- `Map` --references--> `BlueNoise`  [INFERRED]
  .claude/skills/tests/SKILL.md → Sources/MetalRenderer/BlueNoise.swift

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

## Communities (251 total, 24 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (41): GPUEmissiveTriangle, meshLights, BorrowedLight, CityLight, CurveMesh, Float, Instance, .isGeometry (+33 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.05
Nodes (61): Buffer, CustomStringConvertible, Decodable, Error, Node, Primitive, Accessor, AnyDecodable (+53 more)

### Community 3 - "RenderSettings"
Cohesion: 0.11
Nodes (44): Bound, Codable, Equatable, F, Cover, UInt32, UInt64, Ages (+36 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (71): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+63 more)

### Community 5 - "traceKernel"
Cohesion: 0.06
Nodes (73): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+65 more)

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
Nodes (29): AnyObject, Reading the table, ObservableObject, PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn (+21 more)

### Community 11 - "RenderView"
Cohesion: 0.12
Nodes (11): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, RenderView, .acceptsFirstResponder, NSEvent, NSSize (+3 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, RC_MAX_CASCADES, constant, device, float3, float4, kernel, read (+21 more)

### Community 13 - "FramePlan"
Cohesion: 0.18
Nodes (13): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+5 more)

### Community 14 - "Frame"
Cohesion: 0.18
Nodes (7): MTLBlitCommandEncoder, MTLRenderPassDescriptor, Frame, MTLAccelerationStructureCommandEncoder, MTLCommandBuffer, MTLComputeCommandEncoder, MTLRenderCommandEncoder

### Community 15 - "Metal4Frame"
Cohesion: 0.14
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.21
Nodes (13): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+5 more)

### Community 17 - "SDFVolume"
Cohesion: 0.11
Nodes (9): Float16, simd_double3x3, simd_double4x4, SDFVolume, .hi, Float, SDFTests, Float (+1 more)

### Community 18 - "roundToHalf"
Cohesion: 0.14
Nodes (30): 10. GPU tools, 1. Frame structure and submission, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, atrousKernel() (+22 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (42): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+34 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (75): distance, constant, device, float2, float3, float4, kernel, Light (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.44
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "TextureStreamer"
Cohesion: 0.07
Nodes (29): MTLRegion, MTLSparseTextureMappingMode, Entry, Level, SparseMapping, Data, MTLBuffer, MTLCommandBuffer (+21 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.10
Nodes (22): SIMD2, UnsafePointer, Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer (+14 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (50): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+42 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (18): GPUJoint, .parent, GPUSkinVertex, Clip, .duration, .loopKeys, Level, .triangleCount (+10 more)

### Community 27 - "flagOn"
Cohesion: 0.19
Nodes (26): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+18 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (19): Settings: `SettingsTable.swift`, NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader (+11 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (79): 8. Pipelines and resources, MetalKit, GPUFogParams, .reflectionPassFlags, GPUPostParams, GPURegirParams, done, DenoiseSignal (+71 more)

### Community 31 - "LoadingOverlay"
Cohesion: 0.17
Nodes (7): NSView, LoadingOverlay, .isEnabled, NSCoder, NSPoint, NSPoint, Timer

### Community 32 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (31): emptyReservoir(), constant, device, float2, float4, kernel, read, SCENE_ACCEL (+23 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.05
Nodes (53): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams (+45 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "SectionFile"
Cohesion: 0.13
Nodes (12): CryptoKit, MeshGeometry, GeneratedCache, SectionFile, Data, T, UInt32, UnsafeRawBufferPointer (+4 more)

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
Nodes (105): CaseIterable, Role, bush, groundCover, tree, Backend, auto, gpu (+97 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (31): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+23 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (31): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, InstanceBlock, .held, Options (+23 more)

### Community 45 - "View"
Cohesion: 0.10
Nodes (34): Binding, .body, EditorGroup, ParamRow, ParamRows, .body, Root, ValueRow (+26 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.16
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, NSWindow, UndoManager, URL (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "FBXFile"
Cohesion: 0.11
Nodes (20): Compression, IteratorProtocol, Sequence, Children, Connection, Contents, FBXArrayElement, invalid (+12 more)

### Community 51 - "DebugPanel"
Cohesion: 0.11
Nodes (10): DebugPanel, .wasVisible, FrameGraphView, CFTimeInterval, Notification, NSPanel, NSTextField, NSWindow (+2 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (37): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+29 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.10
Nodes (11): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .cellSize, Float, SIMD8, UInt32, UInt64 (+3 more)

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
Nodes (44): BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place, trunk (+36 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (87): 2. Memory bandwidth: the default suspect for screen-space passes, Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt() (+79 more)

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
Cohesion: 0.14
Nodes (15): Int8, float4x4, Baked, bricks, Heightfield, .hi, MeshSDF, .bytes (+7 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "RendererError"
Cohesion: 0.07
Nodes (23): .virtualGeometryChanged, RendererError, .description, missingFunction, unsupported, .indexOffset, Content, MTLAccelerationStructure (+15 more)

### Community 73 - "CityPlan"
Cohesion: 0.11
Nodes (25): Block, CityPlan, Edge, open, party, street, Lamp, Lot (+17 more)

### Community 74 - "SIMD3"
Cohesion: 0.08
Nodes (27): GPUFluidParams, GPUFluidParticle, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, Cloth, PhysicsWorld (+19 more)

### Community 76 - "RenderPass"
Cohesion: 0.09
Nodes (9): Metal3RenderPass, RenderPass, MTLBuffer, MTLDepthStencilState, MTLRenderCommandEncoder, MTLRenderPipelineState, MTLResource, MTLResourceUsage (+1 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.47
Nodes (7): FoliageVoxels, Grid, Piece, Plant, Float, float4x4, UInt32

### Community 78 - "LoadJob"
Cohesion: 0.18
Nodes (9): Sendable, LoadJob, .isCancelled, LoadStep, .isCancelled, MaterialTextures, MTLCommandQueue, MTLDevice (+1 more)

### Community 79 - "BVHBuilder"
Cohesion: 0.12
Nodes (16): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+8 more)

### Community 80 - "KernelVariants"
Cohesion: 0.19
Nodes (16): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Key (+8 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.15
Nodes (9): Job, .heading, LoadActivity, .onChange, Snapshot, .isIdle, Stream, Set (+1 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.20
Nodes (27): lumenClipContains(), lumenClipDistance(), lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel(), lumenGlobalComposeKernel(), LumenGlobalHit, hit (+19 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.13
Nodes (22): Where things are, Built, CutInput, Entry, Float, float4x4, MTLAccelerationStructure, MTLBuffer (+14 more)

### Community 86 - "FluidSystem"
Cohesion: 0.09
Nodes (27): .surfaceCapacity, Float, UInt32, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims (+19 more)

### Community 87 - "Double"
Cohesion: 0.14
Nodes (15): Double, World, MTLDevice, .anchorTile, .start, Block, City, Ground (+7 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.08
Nodes (40): Level, Mesh, Float, Age, mature, sapling, young, Bone (+32 more)

### Community 90 - "FoliageTextures"
Cohesion: 0.15
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (23): heights, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness (+15 more)

### Community 92 - "GPUMesh"
Cohesion: 0.14
Nodes (5): GPUMesh, UInt64, RasterSceneTests, Float, MeshGeometry

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.16
Nodes (8): Metal3Pass, .declarationScope, AnyObject, FluidTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+48 more)

### Community 97 - ".length"
Cohesion: 0.09
Nodes (13): GPUPhysicsGrab, .length, HairTests, Float, MTLCommandQueue, MTLDevice, Void, PhysicsTests (+5 more)

### Community 98 - "MuscleTests"
Cohesion: 0.10
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 99 - "BuildingAssembler"
Cohesion: 0.14
Nodes (15): BuildingAssembler, BuildingGenerator, BuildingSpec, BuildingTier, .top, Footprint, .area, .cover (+7 more)

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
Nodes (8): Building, .triangleCount, Module, Data, float4x4, BuildingTests, Float, SIMD2

### Community 105 - "SurfaceMaterial"
Cohesion: 0.10
Nodes (22): Hashable, SurfaceMaterial, .uvScale, Balustrade, bars, glass, solid, BuildingStyle (+14 more)

### Community 106 - "EnvVariable"
Cohesion: 0.05
Nodes (47): on, Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, showcaseModel (+39 more)

### Community 107 - "Row"
Cohesion: 0.17
Nodes (10): NSFont, Model, heading, item, Row, State, failed, running (+2 more)

### Community 108 - "RasterClusters"
Cohesion: 0.11
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 109 - "RendererController"
Cohesion: 0.13
Nodes (11): DebugInfo, Float, .plantStats, RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus (+3 more)

### Community 110 - "Int32"
Cohesion: 0.36
Nodes (6): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (17): CGPoint, Context, DragGesture, NSViewRepresentable, Catcher, CurveEditor, .canvas, .points (+9 more)

### Community 112 - "WorldTile"
Cohesion: 0.13
Nodes (15): .time, Chunk, .triangles, ChunkRecord, Light, Float, SIMD2, UInt32 (+7 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.10
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (40): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular (+32 more)

### Community 117 - "Bool"
Cohesion: 0.16
Nodes (9): Cell, .center, .width, Opening, Float, SIMD2, Void, Bool (+1 more)

### Community 118 - "lumenTraceKernel"
Cohesion: 0.21
Nodes (28): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel(), LumenScreenHit (+20 more)

### Community 119 - "AABB"
Cohesion: 0.05
Nodes (33): AABB, .area, .centroid, .isEmpty, SDFVolume, Assembly, Bone, BorrowedMesh (+25 more)

### Community 120 - ".library"
Cohesion: 0.11
Nodes (10): Tab, ages, boughs, habitat, leaves, look, stems, FoliageTests (+2 more)

### Community 121 - "Flora"
Cohesion: 0.10
Nodes (16): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.10
Nodes (16): CodingKey, Foliage.Curve, Key, crown, linear, points, taper, Decoder (+8 more)

### Community 125 - "PlantTracing"
Cohesion: 0.07
Nodes (33): Tests, float3x3, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart (+25 more)

### Community 127 - "SDFShape"
Cohesion: 0.09
Nodes (30): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+22 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (30): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4x4 (+22 more)

### Community 129 - "SettingsTableTests"
Cohesion: 0.10
Nodes (8): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, SettingsEnv, ForestTests, SettingsTableTests

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (31): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+23 more)

### Community 132 - "TraversalStats"
Cohesion: 0.33
Nodes (5): UInt64, TraversalStats, .description, .line, .rays

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.11
Nodes (8): PlantMutate, Root, SplitMix64, Host, PlantEditorTests, Root, URL, Void

### Community 135 - "Float"
Cohesion: 0.15
Nodes (9): PhysicsJoint, PhysicsJointKind, ball, hinge, Float, float4x4, SDFShape, UInt32 (+1 more)

### Community 136 - "Benchmark"
Cohesion: 0.04
Nodes (45): To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't, 6. Math, Modes (+37 more)

### Community 137 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 139 - "VoxelLOD"
Cohesion: 0.09
Nodes (24): MTLResource, BoxData, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32, UInt64 (+16 more)

### Community 140 - ".write"
Cohesion: 0.17
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (22): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+14 more)

### Community 143 - "reflectionKernel"
Cohesion: 0.06
Nodes (51): Where things are, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+43 more)

### Community 144 - "GPUMaterial"
Cohesion: 0.30
Nodes (7): GPUMaterial, Assembler, Draft, Data, float4x4, UInt8, Void

### Community 145 - ".draw"
Cohesion: 0.07
Nodes (26): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+18 more)

### Community 146 - "LayerSurface"
Cohesion: 0.15
Nodes (13): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface (+5 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - "LumenMeshSDF"
Cohesion: 0.12
Nodes (17): int4, LumenClipLevel, origin, voxel, LumenMeshSDF, bricks, info, lo (+9 more)

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.17
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - ".buildStress"
Cohesion: 0.09
Nodes (24): OptionSet, Parts, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+16 more)

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (30): ComputePass, MTLBarrierScope, MTLComputePipelineState, MTLComputePipelineState, Step, FluidGPU, .summary, Steps (+22 more)

### Community 153 - "Species"
Cohesion: 0.21
Nodes (11): RawRepresentable, Species, .description, .hasBoughs, .isTree, Habitat, Ramp, Float (+3 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "MeshSDFBuilderTests"
Cohesion: 0.21
Nodes (4): MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 156 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 157 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 158 - "CharacterLibrary"
Cohesion: 0.30
Nodes (5): BlobWriter, CharacterLibrary, .directory, Data, URL

### Community 159 - "XCTestCase"
Cohesion: 0.11
Nodes (20): .data, Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32 (+12 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "AppKit"
Cohesion: 0.21
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "Int"
Cohesion: 0.06
Nodes (29): UnsafeRawPointer, Card, GPULumenCard, LumenCards, .megabytes, Float, MTLBuffer, MTLDevice (+21 more)

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

### Community 173 - "PlantParam"
Cohesion: 0.21
Nodes (9): L, .body, PlantParam, .isInteger, PlantParams, Float, Root, Void (+1 more)

### Community 174 - ".encodeSceneUpdate"
Cohesion: 0.05
Nodes (38): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp (+30 more)

### Community 175 - "device"
Cohesion: 0.29
Nodes (15): device, float3, Light, read, SCENE_ACCEL, texture2d, write, shadowVisible() (+7 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - ".stages"
Cohesion: 0.15
Nodes (13): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 181 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 182 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (8): NSWindowDelegate, PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (13): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+5 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD4"
Cohesion: 0.09
Nodes (18): GPUPhysicsShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box, capsule (+10 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - ".preset"
Cohesion: 0.15
Nodes (3): fog, URL, ShowcaseTests

### Community 189 - "Clip"
Cohesion: 0.23
Nodes (8): .body, Clip, graft, habitat, leaves, level, look, Clipboard

### Community 190 - "SceneSettings"
Cohesion: 0.12
Nodes (6): MeshGeometry, SceneSettings, SIMD2, Float, MeshGeometry, Void

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "SettingsStore"
Cohesion: 0.14
Nodes (8): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, base, SettingsStore, Any, DispatchWorkItem

### Community 193 - "PhysicsSettings"
Cohesion: 0.10
Nodes (18): Darwin, rotate(), Float, float4x4, HairStyle, Float, UInt32, SplitMix (+10 more)

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

### Community 200 - "InputHandler"
Cohesion: 0.27
Nodes (3): InputHandler, Float, SIMD2

### Community 201 - "RagdollTests"
Cohesion: 0.16
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 203 - "SkyImage"
Cohesion: 0.25
Nodes (7): Atmosphere, LoadError, unreadable, SkyImage, Float, Set, URL

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

### Community 219 - "ShadingPoint"
Cohesion: 0.20
Nodes (10): ShadingPoint, albedo, f0, hair, n, ng, p, roughness (+2 more)

### Community 220 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 221 - "RenderThread"
Cohesion: 0.20
Nodes (4): Notification, RenderThread, Thread, Void

### Community 222 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 224 - "PrimitiveWork"
Cohesion: 0.25
Nodes (6): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, PrimitiveWork, .encoderCount, MTLAccelerationStructureCommandEncoder

### Community 225 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 226 - "InstanceData"
Cohesion: 0.22
Nodes (9): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+1 more)

### Community 227 - ".withUnsafeBufferPointer"
Cohesion: 0.25
Nodes (5): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), R, Hasher, .array, UnsafeBufferPointer

### Community 229 - "Map"
Cohesion: 0.10
Nodes (12): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, PipelineCache, .count, KernelVariantsTests (+4 more)

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".part"
Cohesion: 0.14
Nodes (18): simd_quatd, FBXError, .description, StaticString, T, BlobReader, CharacterImporter, concurrently() (+10 more)

### Community 233 - "LumenSDFHit"
Cohesion: 0.29
Nodes (7): LumenSDFHit, hit, id, local, normal, position, t

### Community 234 - "RenderPass4"
Cohesion: 0.17
Nodes (7): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState

### Community 235 - "PlantEditorModel.swift"
Cohesion: 0.40
Nodes (3): Combine, Element, Array

### Community 236 - "Float"
Cohesion: 0.14
Nodes (11): Flora, Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation, Placement (+3 more)

### Community 237 - "WorldPlace"
Cohesion: 0.43
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 239 - "Types.metal"
Cohesion: 0.22
Nodes (8): MaterialTexture, t, texture2d, rayClass(), RegirParams, RegirReservoir, VSMScene, windOn()

### Community 241 - "CameraTrack"
Cohesion: 0.10
Nodes (12): CameraTrack, .duration, Key, Particles, bubbles, dust, embers, none (+4 more)

### Community 243 - "Section"
Cohesion: 0.20
Nodes (7): NSColor, NSStackView, FlippedView, .isFlipped, Section, NSCoder, NSView

### Community 246 - "Detail"
Cohesion: 0.67
Nodes (3): Detail, flat, full

### Community 248 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 250 - ".init"
Cohesion: 0.50
Nodes (3): CGRect, MTLDevice, NSCoder

## Knowledge Gaps
- **1541 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1536 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2112 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **24 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.simplify`, `PlantEditorModel`, `FramePlan`, `Frame`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `View`, `LumenScene`, `Crowd`, `FBXFile`, `DebugPanel`, `SceneKind`, `.xyz`, `MuscleAtlas`, `.build`, `RendererError`, `CityPlan`, `SIMD3`, `RenderPass`, `LoadJob`, `BVHBuilder`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `FluidSystem`, `Double`, `Foliage`, `FoliageTextures`, `SurfaceKind`, `GPUMesh`, `Upscaler`, `Metal3Pass`, `.length`, `MuscleTests`, `BuildingAssembler`, `SoftModel`, `Building`, `EnvVariable`, `Row`, `RasterClusters`, `RendererController`, `Int32`, `CurveEditor`, `WorldTile`, `Bool`, `AABB`, `.library`, `Flora`, `PlantTracing`, `CityTests`, `SDFShape`, `Slot`, `TraversalStats`, `Float`, `Benchmark`, `VoxelLOD`, `.write`, `GPUMaterial`, `LayerSurface`, `.buildStress`, `Pipelines`, `Species`, `Curve`, `MeshSDFBuilderTests`, `XCTestCase`, `PlantParam`, `.encodeSceneUpdate`, `.stages`, `LumenGlobalSDF`, `.encoder`, `FoliageRuntimeTests`, `SIMD4`, `SceneSettings`, `PhysicsSettings`, `RagdollTests`, `SkyImage`, `Buffer`, `Terrain`, `PrimitiveWork`, `Map`, `.commit`, `.part`, `RenderPass4`, `PlantEditorModel.swift`, `Float`, `WorldPlace`, `StressSceneTests`, `.setBytes`, `Detail`, `VirtualGeometry`?**
  _High betweenness centrality (0.312) - this node is a cross-community bridge._
- **Why does `Kernel` connect `Kernel` to `Scene`, `SettingsTableTests`, `Int`, `String`, `FramePlan`, `KernelVariants`, `QuartzCore`, `Pipelines`, `Renderer`?**
  _High betweenness centrality (0.124) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `VoxelLOD`, `.write`, `FluidSurface.metal`, `.buildStress`, `Pipelines`, `TextureStreamer`, `SkinnedCharacter`, `Renderer`, `LoadingOverlay`, `TraceScene`, `XCTestCase`, `Int`, `SectionFile`, `SceneBuffers`, `MuscleAtlas`, `RendererError`, `CityPlan`, `LoadJob`, `Terrain`, `LoadActivity`, `VirtualBLAS`, `Capabilities`, `SurfaceKind`, `Upscaler`, `RasterClusters`, `PlantTracing`?**
  _High betweenness centrality (0.119) - this node is a cross-community bridge._
- **Are the 39 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 39 INFERRED edges - model-reasoned connections that need verification._
- **Are the 27 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 27 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1541 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.04722222222222222 - nodes in this community are weakly interconnected._