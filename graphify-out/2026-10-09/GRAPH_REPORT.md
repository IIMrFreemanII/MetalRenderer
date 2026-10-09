# Graph Report - procedural-character-creation-cb1a51  (2026-10-09)

## Corpus Check
- 286 files · ~1,349,447 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 8163 nodes · 25535 edges · 278 communities (255 shown, 23 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3738 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `774f8431`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Codable
- Lights.metal
- pcgHash
- CharacterEditorModel
- .simplify
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- CGFloat
- rcTraceMergeKernel
- FramePlan
- HairTests
- Metal4Frame
- translate
- .d
- roundToHalf
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- float4x4
- VGStreamer
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- Camera
- FaceRig
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- FaceSculpt
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- BuildingEditorModel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- VirtualGeometry
- LumenGlobalSDF
- SceneSettings
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- FogParams
- Shaders.metal
- VGBlas
- MeshData
- Direct Rendering Stress Test 32
- Config
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- VirtualTracing
- CityPlan
- Int32
- simd
- Metal3Pass
- RendererController
- TextureStreamer
- FoliageTextures
- Pipelines
- ab.sh
- LoadActivity
- LumenSDF.metal
- Ray
- VirtualBLAS
- LotRef
- .bytes
- Capabilities
- Foliage
- CodingKeys
- ProceduralTextures
- geometryDebugKernel
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- CharacterDNA
- Building
- physCollide
- ClusterBox
- SoftModel
- uint4
- Rect
- CaseIterable
- Bool
- SettingsTableTests
- CharacterParam
- EnvVariable
- Int
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysPoints
- render.sh
- BuildingAssembler
- Interior
- .addMesh
- .build
- Flora
- same.sh
- Key
- baseline.sh
- BuildingPlan
- .buildWorld
- BVHBuilder
- Raster.metal
- .load
- CharacterBase
- lumenCardRadiosityKernel
- PhysicsBody
- PlantWind
- Host
- Kind
- Benchmark
- RoomType
- .pieces
- VoxelLOD
- .write
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- .buildings
- RenderView
- .writeDescriptors
- VSMCounters
- .load
- Hit
- QuartzCore
- MeshBuilder
- ComputePass
- .look
- Curve
- Post.metal
- Furnisher
- FloorPlan
- DebugPanel
- MeshSDFBuilderTests
- TraceScene
- Intersect.metal
- ImageIO
- Lift
- related.sh
- VirtualMesh
- RTVoxels
- SplitMix64
- VGParams
- Measuring MetalRenderer
- .add
- .load
- VSM.metal
- BuildingStyleDef
- GPUProfiler
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- CharacterEditorTests
- FleshFigure
- Images
- Slot
- VSMParams
- FoliageRuntimeTests
- .build
- RasterParams
- Role
- BodySurface
- float3
- VSMInstance
- ColliderGrid
- Region
- PlantTracing
- RasterCounters
- SplitMix
- Float
- SDFBox
- SDFShape
- CrowdSkinParams
- RagdollTests
- FurnitureItem
- String
- KernelVariantsTests
- BVHNode
- Role
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- Stored
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- traceKernel
- FBXFile
- uint
- SceneShading
- SkyParams
- LumenParams
- .read
- CharacterBaseTests
- SettingsStore
- SIMD3
- Key
- HairBSDF
- .commit
- .building
- PropLibrary
- RenderPass4
- Custom
- Double
- WorldPlace
- CameraTrack
- .key
- Clip
- Stage
- PlantEditorPanel
- Core
- PlantTracingTests
- Buffer
- LoadingOverlay
- Tab
- VirtualGeometry
- LightKind
- PhysicsSkinAttach
- WallGrid
- PhysicsMuscle
- CharacterEditorPanel
- Heavens
- VoxelGrids
- .encoder
- StressSceneTests
- CharacterRig
- .testTheCutsBLASHoldsTheCutsTriangles
- CharacterMorphs
- Kind
- PostParams
- .curve
- float4
- .init
- WindFrame
- Types.metal
- Foliage.Phyllotaxis
- Metal4Backend.swift
- GPULumenCard
- .capture
- LightMotion
- Optional
- .useResource
- .updatePrimitives
- Shape
- .torusKnotMesh

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 552 edges
2. `Scene` - 338 edges
3. `PhysicsWorld` - 275 edges
4. `Renderer` - 271 edges
5. `simd` - 155 edges
6. `Kernel` - 154 edges
7. `SIMD4` - 153 edges
8. `Foliage` - 151 edges
9. `Benchmark` - 129 edges
10. `RenderSettings` - 115 edges

## Surprising Connections (you probably didn't know these)
- `Recipes` --references--> `DemoWalk`  [INFERRED]
  .claude/skills/offscreen/SKILL.md → Sources/MetalRenderer/Benchmark+BuildingsDemo.swift
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal

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

## Communities (278 total, 23 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.05
Nodes (48): AABB, .area, .centroid, .isEmpty, GPUEmissiveTriangle, meshLights, .viewNote, .walkerStatus (+40 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.11
Nodes (39): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+31 more)

### Community 3 - "Codable"
Cohesion: 0.05
Nodes (81): Bound, Codable, Equatable, Look, Macro, Float, Cover, Habitat (+73 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (79): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+71 more)

### Community 5 - "pcgHash"
Cohesion: 0.06
Nodes (51): constant, device, float2, float3, float4, kernel, thread, uint (+43 more)

### Community 6 - "CharacterEditorModel"
Cohesion: 0.09
Nodes (20): CharacterEditorHost, CharacterEditorModel, .dna, .index, .inWorkshop, .isBuiltIn, .isDirty, .key (+12 more)

### Community 7 - ".simplify"
Cohesion: 0.33
Nodes (6): MeshSimplifier, Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.04
Nodes (47): ObservableObject, .hasBoughs, .isTree, Clip, graft, habitat, leaves, level (+39 more)

### Community 11 - "CGFloat"
Cohesion: 0.12
Nodes (17): NSFont, NSTextField, FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize (+9 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (34): array, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, RC_MAX_CASCADES (+26 more)

### Community 13 - "FramePlan"
Cohesion: 0.10
Nodes (28): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, Things that are not structures yet, Where new code belongs, MetalKit, ComputeStage, FrameEncoder (+20 more)

### Community 14 - "HairTests"
Cohesion: 0.12
Nodes (14): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice, UInt32 (+6 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.12
Nodes (15): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+7 more)

### Community 16 - "translate"
Cohesion: 0.16
Nodes (17): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, rotate(), scale(), translate(), FogVolume, .gpu, LightPose (+9 more)

### Community 17 - ".d"
Cohesion: 0.12
Nodes (8): Float16, simd_double3x3, SDFVolume, .hi, Float, SDFTests, Float, SDFShape

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
Cohesion: 0.05
Nodes (75): distance, makeRay(), constant, device, float2, float3, float4, kernel (+67 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "float4x4"
Cohesion: 0.13
Nodes (16): Parts, GPUMaterial, float4x4, Float, Range, Hall, Loop, .length (+8 more)

### Community 24 - "VGStreamer"
Cohesion: 0.05
Nodes (35): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+27 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (59): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+51 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (18): simd_double4x4, GPUSkinVertex, Clip, .duration, .loopKeys, Level, .triangleCount, Part (+10 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.21
Nodes (28): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel(), LumenScreenHit (+20 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (18): NSControl, NSGridView, NSObject, Action, FlippedView, .isFlipped, SectionHeader, .expanded (+10 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (70): To do on the M4 Max, 4. CPU↔GPU data layout, 8. Pipelines and resources, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, SkyImage, Set, DebugInfo, Float (+62 more)

### Community 31 - "Camera"
Cohesion: 0.12
Nodes (9): Camera, .forward, .worldToView, Float, PlantStats, Float, RasterSceneTests, Float (+1 more)

### Community 32 - "FaceRig"
Cohesion: 0.11
Nodes (20): CharacterKit, UInt32, Entry, FacePlayer, FaceRig, FaceState, Group, leftEye (+12 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.12
Nodes (33): shadowOrigin(), emptyReservoir(), constant, device, float2, float4, kernel, read (+25 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.08
Nodes (36): simd_float4x4, GPUFleshFibre, GPUFleshPin, GPUFogVolume, GPUInstanceData, GPUJoint, GPUJointMatrix, GPUMegaLightsParams (+28 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.11
Nodes (15): CryptoKit, R, GeneratedCache, Hasher, SectionFile, .array, Data, T (+7 more)

### Community 39 - "Physics.metal"
Cohesion: 0.13
Nodes (56): constant, device, int3, kernel, uint, physActivate(), physCell(), physColourPairs() (+48 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "FaceSculpt"
Cohesion: 0.12
Nodes (16): FaceParts, Material, brows, iris, lips, mouth, pupil, sclera (+8 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (67): FaceExpression, cycle, frown, neutral, smile, surprise, talk, .title (+59 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (32): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2 (+24 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (34): .empty, LoadOptions, PreparedScene, .namedPrimitives, RendererError, .description, missingFunction, Replaced (+26 more)

### Community 45 - "BuildingEditorModel"
Cohesion: 0.04
Nodes (82): BuildingEditorHost, BuildingEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .savedDef, .workshopSettings (+74 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.16
Nodes (12): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source, Float (+4 more)

### Community 48 - "AppDelegate"
Cohesion: 0.09
Nodes (16): NSApplication, NSApplicationDelegate, NSMenuItem, BuildingEditorPanel, .isVisible, .wasVisible, Notification, NSPanel (+8 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (20): .parts, Crowd, .liveStates, Face, Motion, .isBlend, Part, Slot (+12 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.10
Nodes (21): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLDevice (+13 more)

### Community 51 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (11): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+3 more)

### Community 52 - "SceneSettings"
Cohesion: 0.03
Nodes (60): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08) (+52 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.06
Nodes (35): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, GPUPhysicsParticle (+27 more)

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
Cohesion: 0.22
Nodes (10): Mark, Muscle, MuscleAtlas, Place, Shape, Float, Range, SIMD2 (+2 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (108): Material, metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3 (+100 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "Config"
Cohesion: 0.10
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.06
Nodes (24): .instanceAS, .virtualGeometryChanged, Content, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64 (+16 more)

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (33): .entry, .well, .name, Block, CityPlan, Edge, open, party (+25 more)

### Community 74 - "Int32"
Cohesion: 0.08
Nodes (26): Int32, .surfaceCapacity, Float, UInt32, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, LocalIds (+18 more)

### Community 76 - "Metal3Pass"
Cohesion: 0.06
Nodes (19): Metal3Pass, .declarationScope, Metal3RenderPass, RenderPass, AnyObject, MTLBarrierScope, MTLBuffer, MTLComputeCommandEncoder (+11 more)

### Community 77 - "RendererController"
Cohesion: 0.10
Nodes (14): .buildingPlan, .buildingStats, .cameraPosition, .walker, Float, .characterStats, .plantStats, RendererController (+6 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.06
Nodes (35): Map, MTLRegion, MTLSparseTextureMappingMode, LoadStep, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture (+27 more)

### Community 79 - "FoliageTextures"
Cohesion: 0.16
Nodes (16): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+8 more)

### Community 80 - "Pipelines"
Cohesion: 0.18
Nodes (19): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, Pipelines (+11 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.11
Nodes (15): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled (+7 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (21): geometry_type, anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery() (+13 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.15
Nodes (19): Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue, MTLDevice (+11 more)

### Community 86 - "LotRef"
Cohesion: 0.06
Nodes (29): Where things are, Hashable, P, .currentOverride, .currentRef, .key, BuildingMutate, BuildingParams (+21 more)

### Community 88 - "Capabilities"
Cohesion: 0.20
Nodes (7): Capabilities: `Capabilities.swift`, Capabilities, .summary, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.04
Nodes (62): Card, Level, Mesh, Plant, RawRepresentable, Skeleton, Float, Age (+54 more)

### Community 90 - "CodingKeys"
Cohesion: 0.07
Nodes (23): CharacterDNA.Look, CharacterDNA.Macro, CodingKeys, age, basedOn, bones, eyes, format (+15 more)

### Community 91 - "ProceduralTextures"
Cohesion: 0.18
Nodes (10): Maps, ProceduralTextures, Data, Float, Sample, SIMD2, UInt32, UInt8 (+2 more)

### Community 92 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (12): Float, SIMD2, UpscaleInputs, AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture (+4 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.09
Nodes (18): FluidWorld, LiquidKind, blood, honey, .look, .name, .physics, water (+10 more)

### Community 96 - "quatRotate"
Cohesion: 0.06
Nodes (52): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+44 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.14
Nodes (7): GPUPhysicsGrab, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "CharacterDNA"
Cohesion: 0.13
Nodes (13): CharacterDNA, .key, T, UInt64, BuiltInCharacters, .launch, CharacterStore, .folder (+5 more)

### Community 99 - "Building"
Cohesion: 0.08
Nodes (29): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail, flat (+21 more)

### Community 100 - "physCollide"
Cohesion: 0.12
Nodes (30): thread, physAdd(), physAddFound(), physAgree(), physArea(), PhysCandidate, n, pa (+22 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (18): ArraySlice, centre, NearCache, SoftModel, .near, .radius, Float, MeshGeometry (+10 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (45): uint4, PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad (+37 more)

### Community 104 - "Rect"
Cohesion: 0.17
Nodes (12): PlanDoor, PlanRoom, .area, StoreyPlanner, Float, SIMD2, SplitMix64, Rect (+4 more)

### Community 105 - "CaseIterable"
Cohesion: 0.03
Nodes (82): CaseIterable, Balustrade, bars, glass, solid, PlanShape, courtyard, l (+74 more)

### Community 106 - "Bool"
Cohesion: 0.09
Nodes (20): F, RenderSettings, Bool, .envText, Control, checkbox, custom, popup (+12 more)

### Community 107 - "SettingsTableTests"
Cohesion: 0.14
Nodes (3): Settings: `SettingsTable.swift`, SettingsEnv, SettingsTableTests

### Community 108 - "CharacterParam"
Cohesion: 0.11
Nodes (15): Group, .body, CharacterGroup, .body, CharacterParam, CharacterParams, .faceSections, Group (+7 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 110 - "Int"
Cohesion: 0.04
Nodes (38): GPUFogParams, .reflectionPassFlags, GPUPostParams, GPUSkyParams, Lumen, LumenParams, LumenPipelines, LumenRadiosityParams (+30 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (18): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+10 more)

### Community 112 - "WorldTile"
Cohesion: 0.11
Nodes (18): Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data, Float (+10 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.11
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysPoints"
Cohesion: 0.12
Nodes (17): physContactPush(), PhysicsContact, anchorA, anchorB, lambda, normal, PhysPoints, pa (+9 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.17
Nodes (13): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+5 more)

### Community 118 - "Interior"
Cohesion: 0.13
Nodes (21): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+13 more)

### Community 119 - ".addMesh"
Cohesion: 0.08
Nodes (9): GLTFModel, .bounds, .triangleCount, Light, GPUMesh, UInt64, MeshGeometry, URL (+1 more)

### Community 120 - ".build"
Cohesion: 0.16
Nodes (15): Int8, Baked, bricks, heights, Heightfield, .hi, MeshSDF, .bytes (+7 more)

### Community 121 - "Flora"
Cohesion: 0.10
Nodes (16): Flora, .name, Placed, assembly, flat, Prepared, boxes, flat (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (14): CodingKey, Keys, hi, lo, Foliage.Curve, Key, crown, linear (+6 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.26
Nodes (5): DemoWalk, Point, Float, SIMD2, BuildingPlan

### Community 126 - ".buildWorld"
Cohesion: 0.09
Nodes (23): SurfaceMaterial, .uvScale, Prop, SurfaceKind, asphalt, brick, concrete, .hasRoughness (+15 more)

### Community 127 - "BVHBuilder"
Cohesion: 0.15
Nodes (13): BinScratch, BVHBuilder, Node, Part, built, .count, split, UnsafeMutablePointer (+5 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (42): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, float4 (+34 more)

### Community 129 - ".load"
Cohesion: 0.15
Nodes (14): CustomStringConvertible, Error, LoadError, unreadable, GLTFError, .description, invalid, unsupported (+6 more)

### Community 130 - "CharacterBase"
Cohesion: 0.12
Nodes (18): Character creator: handoff, Decisions (the user's), Deviations from the plan, and why, Open, Phases, Traps found, CharacterBase, Hand (+10 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (51): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+43 more)

### Community 132 - "PhysicsBody"
Cohesion: 0.13
Nodes (17): physBetween(), physConj(), PhysicsBody, angular, info, invInertia, position, prevPosition (+9 more)

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.08
Nodes (13): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+5 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (36): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+28 more)

### Community 138 - ".pieces"
Cohesion: 0.39
Nodes (6): Piece, SkeletonAtlas, Solid, Float, simd_float3x3, UInt32

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): .megabytes, Entry, Float, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - ".write"
Cohesion: 0.18
Nodes (9): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, CacheFile, Data (+1 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (27): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+19 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.08
Nodes (44): RasterClusterMeshOut, constant, device, float4, kernel, read, texture2d, thread (+36 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (19): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial(), constant, device (+11 more)

### Community 144 - ".buildings"
Cohesion: 0.19
Nodes (7): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (18): AnyObject, CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder (+10 more)

### Community 146 - ".writeDescriptors"
Cohesion: 0.23
Nodes (6): Tests, float3x3, RTPart, Float, UInt32, Wind

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (12): intersection_type, committedCurve(), Hit, barycentrics, cluster, hit, instance, part (+4 more)

### Community 150 - "QuartzCore"
Cohesion: 0.09
Nodes (7): AppKit, Combine, Element, QuartzCore, Array, Headless, SwiftUI

### Community 151 - "MeshBuilder"
Cohesion: 0.14
Nodes (12): OptionSet, .triangleCount, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+4 more)

### Community 152 - "ComputePass"
Cohesion: 0.07
Nodes (27): ComputePass, MTLComputePipelineState, FluidGPU, .summary, Steps, MTLBuffer, MTLComputePipelineState, MTLDevice (+19 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 156 - "Furnisher"
Cohesion: 0.12
Nodes (19): Side, Furnisher, FurnishPalette, Light, Prefer, any, away, corner (+11 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (6): CGSize, FloorPlan, .height, BuildingPlanTests, Float, SIMD2

### Community 158 - "DebugPanel"
Cohesion: 0.08
Nodes (17): NSColor, NSRect, NSStackView, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView (+9 more)

### Community 159 - "MeshSDFBuilderTests"
Cohesion: 0.21
Nodes (4): MeshSDFBuilderTests, SplitMix, Float, UInt64

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (17): intersection_params, assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true> (+9 more)

### Community 162 - "ImageIO"
Cohesion: 0.21
Nodes (3): CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "VirtualMesh"
Cohesion: 0.17
Nodes (15): Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32, UInt64 (+7 more)

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (34): isFar(), constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster (+26 more)

### Community 169 - "Measuring MetalRenderer"
Cohesion: 0.09
Nodes (16): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, A/B protocol, Kernel variants, Launch time (+8 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - ".load"
Cohesion: 0.17
Nodes (11): Data, URL, FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory (+3 more)

### Community 172 - "VSM.metal"
Cohesion: 0.17
Nodes (40): constant, device, float3, float4, fragment, kernel, Light, read (+32 more)

### Community 173 - "BuildingStyleDef"
Cohesion: 0.07
Nodes (35): Encodable, JSONEncoder, Clipboard, .fingerprint, .launch, BuildingStore, .encoder, .folder (+27 more)

### Community 174 - "GPUProfiler"
Cohesion: 0.06
Nodes (28): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+20 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.11
Nodes (25): Color, GraphicsContext, FloorPlanView, .body, .help, .picked, .status, .storeys (+17 more)

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (15): int2, VSMView, flags, kind, level, light, origin, pages (+7 more)

### Community 177 - "PlantParam"
Cohesion: 0.21
Nodes (9): L, .body, PlantParam, .isInteger, PlantParams, Float, Root, Void (+1 more)

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (14): depth2d_array, VSMScene, bias, camera, flags, forward, lightCount, lights (+6 more)

### Community 180 - "CharacterEditorTests"
Cohesion: 0.22
Nodes (4): CharacterEditorTests, Host, URL, Void

### Community 181 - "FleshFigure"
Cohesion: 0.11
Nodes (19): GPUSoftVertex, .cells, Flesh, MuscleSpec, Side, back, front, out (+11 more)

### Community 182 - "Images"
Cohesion: 0.20
Nodes (3): 6. Math, Modes, Images

### Community 183 - "Slot"
Cohesion: 0.10
Nodes (19): Slot, accent, blind, dark, floor, frame, glass, interior (+11 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - ".build"
Cohesion: 0.35
Nodes (5): CharacterBuilder, CharacterShape, MacroRig, Float, simd_float3x3

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "BodySurface"
Cohesion: 0.23
Nodes (5): BodyMarks, BodySurface, .bounds, trunk, MeshGeometry

### Community 190 - "float3"
Cohesion: 0.11
Nodes (30): float3, physAcross(), physAnchorTurnWeight(), physBox(), physBoxGradient(), physContactKick(), physDampJoint(), physHold() (+22 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.28
Nodes (8): ColliderGrid, Input, Moving, Float, SIMD2, Walker, .eyePosition, .height

### Community 193 - "Region"
Cohesion: 0.15
Nodes (13): Region, arm, foot, hand, head, leftEye, leg, lowerTeeth (+5 more)

### Community 194 - "PlantTracing"
Cohesion: 0.14
Nodes (17): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder (+9 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "SplitMix"
Cohesion: 0.47
Nodes (3): SplitMix, Float, UInt64

### Community 197 - "Float"
Cohesion: 0.11
Nodes (12): GPUFleshHeader, Cloth, PhysicsJoint, PhysicsJointKind, ball, hinge, Float, SDFShape (+4 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "SDFShape"
Cohesion: 0.10
Nodes (29): Kind, arrays, block, clusters, skip, virtual, Node, .transform (+21 more)

### Community 200 - "CrowdSkinParams"
Cohesion: 0.15
Nodes (13): CrowdSkinParams, bindBase, currentBase, faceBase, faceScale, faceTargets, firstSlot, groupBase (+5 more)

### Community 201 - "RagdollTests"
Cohesion: 0.17
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.35
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "String"
Cohesion: 0.07
Nodes (19): MTLBlitCommandEncoder, MTLRenderPassDescriptor, Float, MaterialDef, CatalogRegistry, T, Tab, body (+11 more)

### Community 204 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 205 - "BVHNode"
Cohesion: 0.32
Nodes (4): BVHNode, Float, UInt32, tree

### Community 206 - "Role"
Cohesion: 0.17
Nodes (12): Role, chest, foot, forearm, hand, head, neck, pelvis (+4 more)

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
Cohesion: 0.05
Nodes (38): float4, physBreeze(), PhysicsFleshFibre, compliance, g, muscle, pad0, pad1 (+30 more)

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 213 - "Stored"
Cohesion: 0.10
Nodes (15): Instance, .isGeometry, .isStatic, .moves, InstanceGroup, Stored, .count, made (+7 more)

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "traceKernel"
Cohesion: 0.10
Nodes (49): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+41 more)

### Community 220 - "FBXFile"
Cohesion: 0.08
Nodes (33): Compression, IteratorProtocol, Sequence, simd_quatd, Children, Connection, Contents, FBXArrayElement (+25 more)

### Community 221 - "uint"
Cohesion: 0.29
Nodes (12): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+4 more)

### Community 222 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - "LumenParams"
Cohesion: 0.25
Nodes (8): LumenParams, grid, options, screen, sdf, tuning, float4, uint4

### Community 225 - ".read"
Cohesion: 0.22
Nodes (4): .data, URL, CacheTests, URL

### Community 227 - "SettingsStore"
Cohesion: 0.09
Nodes (13): The pass, The pass after a feature, The report and the commit message, What stays fixed, What to look for, base, Notification, RenderThread (+5 more)

### Community 228 - "SIMD3"
Cohesion: 0.08
Nodes (26): Atmosphere, Float, GPUPhysicsShape, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath (+18 more)

### Community 229 - "Key"
Cohesion: 0.39
Nodes (4): Key, PipelineCache, .count, Value

### Community 231 - ".commit"
Cohesion: 0.28
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - ".building"
Cohesion: 0.40
Nodes (4): Float, SIMD2, Walker, WalkerTests

### Community 233 - "PropLibrary"
Cohesion: 0.44
Nodes (5): Entry, File, PropLibrary, Float, URL

### Community 234 - "RenderPass4"
Cohesion: 0.14
Nodes (8): MTL4RenderCommandEncoder, RenderPass4, MTLAccelerationStructure, MTLAllocation, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 235 - "Custom"
Cohesion: 0.20
Nodes (10): Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, showcaseModel, skyImage (+2 more)

### Community 236 - "Double"
Cohesion: 0.10
Nodes (21): Launch, Double, .time, World, .anchorTile, .start, City, Ground (+13 more)

### Community 237 - "WorldPlace"
Cohesion: 0.43
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "CameraTrack"
Cohesion: 0.08
Nodes (17): CameraTrack, .duration, Event, callLift, flashlight, lights, Key, Float (+9 more)

### Community 240 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (7): PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 244 - "PlantTracingTests"
Cohesion: 0.36
Nodes (3): PlantTracingTests, MTLCommandQueue, MTLDevice

### Community 245 - "Buffer"
Cohesion: 0.14
Nodes (11): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLCommandBuffer, MTLHeap (+3 more)

### Community 246 - "LoadingOverlay"
Cohesion: 0.12
Nodes (14): NSPoint, NSView, LoadingOverlay, .isEnabled, Model, heading, item, Row (+6 more)

### Community 247 - "Tab"
Cohesion: 0.25
Nodes (8): Tab, facade, floors, furnish, look, massing, rooms, site

### Community 248 - "VirtualGeometry"
Cohesion: 0.40
Nodes (5): VirtualGeometry, blas, clusters, off, .triangles

### Community 249 - "LightKind"
Cohesion: 0.25
Nodes (8): LightKind, .isSun, mesh, rect, sphere, spot, sun, tube

### Community 250 - "PhysicsSkinAttach"
Cohesion: 0.25
Nodes (8): PhysicsSkinAttach, bary, compliance, deep, ids, pad0, pad1, particle

### Community 251 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "CharacterEditorPanel"
Cohesion: 0.19
Nodes (8): NSWindowDelegate, CharacterEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 254 - "Heavens"
Cohesion: 0.25
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - "VoxelGrids"
Cohesion: 0.18
Nodes (16): FoliageVoxels, Grid, Piece, Plant, Float, UInt32, BoxData, MTLAccelerationStructure (+8 more)

### Community 256 - ".encoder"
Cohesion: 0.22
Nodes (4): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope, MTLSize

### Community 258 - "CharacterRig"
Cohesion: 0.48
Nodes (4): .programme, CharacterRig, Float, simd_quatf

### Community 259 - ".testTheCutsBLASHoldsTheCutsTriangles"
Cohesion: 0.33
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are

### Community 260 - "CharacterMorphs"
Cohesion: 0.11
Nodes (24): Kind, furniture, glass, solid, stair, Float, Bump, CharacterMorphs (+16 more)

### Community 261 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 262 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

### Community 263 - ".curve"
Cohesion: 0.40
Nodes (4): Axis, along, front, up

### Community 264 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 266 - "WindFrame"
Cohesion: 0.31
Nodes (7): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey

### Community 267 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 268 - "Foliage.Phyllotaxis"
Cohesion: 0.28
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 270 - "GPULumenCard"
Cohesion: 0.50
Nodes (3): GPULumenCard, Float, UInt32

### Community 271 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

### Community 272 - "LightMotion"
Cohesion: 0.50
Nodes (4): LightMotion, animated, constant, scaleOnly

### Community 273 - "Optional"
Cohesion: 0.33
Nodes (3): MTLCommandEncoder, Optional, .clipName

### Community 275 - ".updatePrimitives"
Cohesion: 0.29
Nodes (4): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLAccelerationStructureCommandEncoder

### Community 276 - "Shape"
Cohesion: 0.67
Nodes (3): Shape, box, sphere

## Knowledge Gaps
- **1832 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1827 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2453 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **23 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Codable`, `CharacterEditorModel`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `.d`, `LightTable`, `float4x4`, `VGStreamer`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Camera`, `FaceRig`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `FaceSculpt`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `BuildingEditorModel`, `LumenScene`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneSettings`, `PhysicsWorld`, `MuscleAtlas`, `Config`, `VirtualTracing`, `CityPlan`, `Int32`, `Metal3Pass`, `TextureStreamer`, `FoliageTextures`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Foliage`, `ProceduralTextures`, `Upscaler`, `FluidTests`, `PhysicsTests`, `Building`, `SoftModel`, `Rect`, `CaseIterable`, `Bool`, `CharacterParam`, `EnvVariable`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `.addMesh`, `.build`, `Flora`, `BuildingPlan`, `.buildWorld`, `BVHBuilder`, `.load`, `CharacterBase`, `Benchmark`, `RoomType`, `.pieces`, `VoxelLOD`, `.write`, `.writeDescriptors`, `QuartzCore`, `MeshBuilder`, `ComputePass`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `MeshSDFBuilderTests`, `Lift`, `SplitMix64`, `BuildingStyleDef`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `Images`, `Slot`, `FoliageRuntimeTests`, `Role`, `BodySurface`, `ColliderGrid`, `PlantTracing`, `Float`, `SDFShape`, `RagdollTests`, `FurnitureItem`, `String`, `BVHNode`, `Terrain`, `Stored`, `FBXFile`, `.read`, `SIMD3`, `Key`, `.commit`, `.building`, `PropLibrary`, `RenderPass4`, `Double`, `WorldPlace`, `CameraTrack`, `.key`, `PlantTracingTests`, `Buffer`, `LoadingOverlay`, `VirtualGeometry`, `LightKind`, `.encoder`, `StressSceneTests`, `CharacterRig`, `CharacterMorphs`, `.curve`, `.init`, `WindFrame`, `.updatePrimitives`, `.torusKnotMesh`?**
  _High betweenness centrality (0.280) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `Codable`, `CharacterEditorModel`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `translate`, `VGStreamer`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `Camera`, `FaceRig`, `GeneratedCache`, `SettingsTable.swift`, `SceneBuffers`, `BuildingEditorModel`, `VirtualGeometry`, `SceneSettings`, `MuscleAtlas`, `Config`, `VirtualTracing`, `CityPlan`, `RendererController`, `TextureStreamer`, `FoliageTextures`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Capabilities`, `Foliage`, `CodingKeys`, `Upscaler`, `FluidTests`, `CharacterDNA`, `CaseIterable`, `Bool`, `SettingsTableTests`, `CharacterParam`, `EnvVariable`, `Int`, `CurveEditor`, `WorldTile`, `.addMesh`, `Flora`, `Key`, `BuildingPlan`, `.buildWorld`, `BVHBuilder`, `.load`, `CharacterBase`, `Kind`, `Benchmark`, `RoomType`, `.pieces`, `.load`, `ComputePass`, `.look`, `Curve`, `FloorPlan`, `DebugPanel`, `Lift`, `VirtualMesh`, `.add`, `.load`, `BuildingStyleDef`, `GPUProfiler`, `FloorPlanView`, `PlantParam`, `CharacterEditorTests`, `FleshFigure`, `Images`, `.build`, `KernelVariantsTests`, `Stored`, `FBXFile`, `.read`, `SettingsStore`, `SIMD3`, `.commit`, `PropLibrary`, `Double`, `CameraTrack`, `Clip`, `Buffer`, `LoadingOverlay`, `Tab`, `VoxelGrids`, `.encoder`, `CharacterRig`, `CharacterMorphs`, `Kind`, `.updatePrimitives`?**
  _High betweenness centrality (0.169) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `Codable`, `CharacterEditorModel`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `translate`, `float4x4`, `VGStreamer`, `SettingsPanel`, `Renderer`, `FaceRig`, `FaceSculpt`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `BuildingEditorModel`, `LumenScene`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneSettings`, `PhysicsWorld`, `Config`, `VirtualTracing`, `CityPlan`, `Int32`, `RendererController`, `TextureStreamer`, `FoliageTextures`, `Pipelines`, `LoadActivity`, `VirtualBLAS`, `LotRef`, `Foliage`, `Upscaler`, `PhysicsTests`, `Building`, `SoftModel`, `Rect`, `SettingsTableTests`, `CharacterParam`, `EnvVariable`, `Int`, `WorldTile`, `BuildingAssembler`, `Interior`, `.addMesh`, `.build`, `Flora`, `BuildingPlan`, `.buildWorld`, `CharacterBase`, `Benchmark`, `RoomType`, `VoxelLOD`, `RenderView`, `.writeDescriptors`, `.load`, `MeshBuilder`, `ComputePass`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `Lift`, `VirtualMesh`, `.load`, `BuildingStyleDef`, `GPUProfiler`, `PlantParam`, `FleshFigure`, `Slot`, `FoliageRuntimeTests`, `.build`, `ColliderGrid`, `PlantTracing`, `Float`, `SDFShape`, `RagdollTests`, `String`, `BVHNode`, `Stored`, `FBXFile`, `SettingsStore`, `SIMD3`, `Key`, `.commit`, `Double`, `CameraTrack`, `.key`, `PlantEditorPanel`, `Core`, `LoadingOverlay`, `VirtualGeometry`, `LightKind`, `WallGrid`, `CharacterEditorPanel`, `Heavens`, `VoxelGrids`, `.encoder`, `WindFrame`, `.capture`?**
  _High betweenness centrality (0.147) - this node is a cross-community bridge._
- **Are the 54 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 54 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1832 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.04868686868686869 - nodes in this community are weakly interconnected._