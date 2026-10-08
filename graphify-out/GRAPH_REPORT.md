# Graph Report - procedural-character-creation-cb1a51  (2026-10-08)

## Corpus Check
- 280 files · ~1,330,774 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 28 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 4)

## Summary
- 7998 nodes · 24835 edges · 266 communities (245 shown, 21 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3610 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `a342f611`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Codable
- Lights.metal
- reflectionKernel
- Foliage.Phyllotaxis
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
- CharacterEditorModel
- atrousKernel
- Fog.metal
- Sky.metal
- pathTraceKernel
- LightTable
- float4x4
- RasterClusters
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- .shared
- regirBuildKernel
- restirTemporalKernel
- restirGIInitialKernel
- RadianceCascades
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- CharacterDNA
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- Crowd
- VirtualGeometry
- LumenGlobalSDF
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
- FluidSystem
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- Int
- CityPlan
- PhysicsWorld
- simd
- CharacterBase
- FoliageVoxels
- TextureStreamer
- FoliageTextures
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- uint
- VirtualBLAS
- BuildingEditorModel
- .bytes
- Capabilities
- Foliage
- Images
- SurfaceKind
- Where things are
- Upscaler
- megaLightsSampleKernel
- FluidTests
- quatRotate
- PhysicsTests
- MuscleTests
- Building
- float3
- ClusterBox
- SoftModel
- uint4
- Bool
- CaseIterable
- SettingsTable
- .trees
- LotRef
- EnvVariable
- CharacterParam
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysPoints
- render.sh
- BuildingAssembler
- Interior
- RendererController
- .meshes
- Flora
- same.sh
- Key
- baseline.sh
- GLTFModel
- .buildWorld
- SDFShape
- Raster.metal
- RenderSettings
- .building
- lumenCardRadiosityKernel
- Config
- PlantWind
- PlantEditorTests
- Kind
- Benchmark
- RoomType
- RasterVGParams
- VoxelLOD
- VGStreamer
- FluidSurface.metal
- RasterClusters.metal
- geometryDebugKernel
- .env
- RenderView
- Map
- VSMCounters
- .load
- Hit
- QuartzCore
- MeshBuilder
- Pipelines
- Int32
- Curve
- Where things are
- Furnisher
- FloorPlan
- DebugPanel
- FBXFile
- TraceScene
- Intersect.metal
- AppKit
- Lift
- related.sh
- CameraTrack
- RTVoxels
- .buildGallery
- VGParams
- CPU (Swift) practices for MetalRenderer
- .add
- CharacterLibrary
- VSM.metal
- Post.metal
- Metal3Pass
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- FleshFigure
- .writeDescriptors
- WindFrame
- VSMParams
- FoliageRuntimeTests
- SIMD3
- RasterParams
- Role
- GPULight
- PhysicsBody
- VSMInstance
- ColliderGrid
- BuildingEditorPanel
- .build
- RasterCounters
- SplitMix
- LightKind
- SDFBox
- GPU (Metal / MSL) practices for MetalRenderer
- RasterInstance
- RagdollTests
- FurnitureItem
- String
- .encoder
- .stages
- PostParams
- Terrain
- PhysicsConstraint
- PhysicsGroup
- float4
- PhysicsPair
- PhysicsPoseParams
- StressSceneTests
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogNoise.swift
- traceKernel
- LightTreeTests
- CharacterEditorPanel
- SceneShading
- SkyParams
- float4
- CharacterBaseTests
- KernelVariantsTests
- RenderThread
- Buffer
- Key
- HairBSDF
- .commit
- SceneSettings
- .keep
- RenderPass4
- .updatePrimitives
- Double
- WorldPlace
- Particles
- XCTestCase
- Clip
- Stage
- PlantEditorPanel
- Core
- .mark
- Region
- LoadingOverlay
- Op
- DebugInfo
- RasterScene
- VGRasterInstance
- WallGrid
- PhysicsMuscle
- Types.metal
- Heavens
- Measuring MetalRenderer
- clusterWalk
- vsmFragment
- .useResource
- Metal4Backend.swift
- CharacterMorphs
- Kind
- .capture
- .worldView
- .dispatchThreadgroups
- .setComputePipelineState

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 505 edges
2. `Scene` - 336 edges
3. `PhysicsWorld` - 275 edges
4. `Renderer` - 270 edges
5. `Kernel` - 154 edges
6. `SIMD4` - 152 edges
7. `Foliage` - 151 edges
8. `simd` - 149 edges
9. `Benchmark` - 117 edges
10. `RenderSettings` - 115 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
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

## Communities (266 total, 21 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.03
Nodes (62): AABB, .area, .centroid, .isEmpty, GPUEmissiveTriangle, meshLights, Assembly, Bone (+54 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (60): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Binned SAH Bottom-Level BVH (CPU), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Concurrent Encoder Overlap of Cascades and Denoiser, Cornell Room Scene (+52 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.10
Nodes (40): Buffer, Decodable, Node, Primitive, Accessor, AnyDecodable, Asset, Buffer (+32 more)

### Community 3 - "Codable"
Cohesion: 0.05
Nodes (74): Codable, Equatable, Clipboard, File, Balustrade, bars, glass, solid (+66 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (70): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+62 more)

### Community 5 - "reflectionKernel"
Cohesion: 0.04
Nodes (74): metal_raytracing, metal_stdlib, glassKernel(), glassReflection(), constant, device, float3, kernel (+66 more)

### Community 6 - "Foliage.Phyllotaxis"
Cohesion: 0.28
Nodes (5): Foliage.Phyllotaxis, FoliageTextures.Kind, .all, Decoder, Encoder

### Community 7 - ".simplify"
Cohesion: 0.17
Nodes (12): Quadric, Float, SIMD2, UInt32, UnsafeBufferPointer, Sides, backToBack, corner (+4 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (94): FLUID_LIST_BUFFERS, FLUID_WORLD, fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf() (+86 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (34): glob, math, numpy, os, pil, re, shutil, struct (+26 more)

### Community 10 - "PlantEditorModel"
Cohesion: 0.05
Nodes (39): ObservableObject, Clip, graft, habitat, leaves, level, look, Clipboard (+31 more)

### Community 11 - "CGFloat"
Cohesion: 0.15
Nodes (15): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface (+7 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (29): array, 5. Reductions, atomics and threadgroup memory, RC_MAX_CASCADES, constant, device, float3, float4, kernel (+21 more)

### Community 13 - "FramePlan"
Cohesion: 0.09
Nodes (31): 1. The frame loop (`Renderer.draw`), Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, The frame: `Renderer.swift`, MetalKit, ComputeStage, FrameEncoder, RenderAttachments, Float (+23 more)

### Community 14 - "HairTests"
Cohesion: 0.14
Nodes (13): BoxData, SDFBuffers, .buffers, MTLAccelerationStructure, MTLBuffer, MTLDevice, UInt32, UInt64 (+5 more)

### Community 15 - "Metal4Frame"
Cohesion: 0.14
Nodes (14): CAMetalLayer, MTL4ArgumentTable, MTL4CommandAllocator, MTL4CommandQueue, MTL4Compiler, MTLResidencySet, MTLSharedEvent, Metal4Frame (+6 more)

### Community 16 - "translate"
Cohesion: 0.17
Nodes (15): Darwin, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Float (+7 more)

### Community 17 - "CharacterEditorModel"
Cohesion: 0.07
Nodes (24): CharacterEditorHost, CharacterEditorModel, .dna, .index, .inWorkshop, .isBuiltIn, .isDirty, .key (+16 more)

### Community 18 - "atrousKernel"
Cohesion: 0.21
Nodes (22): 9. Shader helpers: use them, don't copy, atrousKernel(), depthGradient(), geometryWeights(), constant, float2, float3, float4 (+14 more)

### Community 19 - "Fog.metal"
Cohesion: 0.15
Nodes (43): FogVolume, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+35 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (42): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+34 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (76): makeRay(), liquidFresnel(), constant, device, float2, float3, float4, kernel (+68 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (6): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, Float, UInt32

### Community 23 - "float4x4"
Cohesion: 0.14
Nodes (15): Parts, GPUMaterial, rotate(), float4x4, Hall, Loop, .length, Props (+7 more)

### Community 24 - "RasterClusters"
Cohesion: 0.10
Nodes (21): Result, Params, RasterClusters, .drawnByCamera, .stats, .summary, Float, MTLBuffer (+13 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (59): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+51 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.12
Nodes (19): simd_double4x4, GPUJoint, GPUSkinVertex, Clip, .duration, .loopKeys, Level, .triangleCount (+11 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.14
Nodes (37): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams, grid (+29 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (135): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+127 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.11
Nodes (17): NSControl, NSGridView, Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel (+9 more)

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (65): 8. Pipelines and resources, Error, LoadError, unreadable, SkyImage, Set, GPUSkyParams, done (+57 more)

### Community 31 - ".shared"
Cohesion: 0.14
Nodes (5): GPUMesh, UInt64, RasterSceneTests, Float, MeshGeometry

### Community 32 - "regirBuildKernel"
Cohesion: 0.12
Nodes (26): constant, device, float2, float3, float4, kernel, thread, uint (+18 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (31): shadowOrigin(), emptyReservoir(), constant, device, float2, float4, kernel, read (+23 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (45): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+37 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (13): Cascade, RadianceCascades, RCParams, RCPipelines, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 36 - "GPUTypes.swift"
Cohesion: 0.08
Nodes (39): simd_float4x4, GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUHairGroup (+31 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (12): 3D Scene Composition, Blue Sphere, Multi-color Palette Design, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Soft Lighting and Material Properties, Red Tilted Rectangular Plane (+4 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.08
Nodes (20): CryptoKit, R, GeneratedCache, Hasher, SectionFile, Stored, .array, .count (+12 more)

### Community 39 - "Physics.metal"
Cohesion: 0.13
Nodes (56): constant, device, int3, kernel, uint, physActivate(), physCell(), physColourPairs() (+48 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "CharacterDNA"
Cohesion: 0.06
Nodes (34): CharacterDNA, .key, CharacterDNA.Look, CharacterDNA.Macro, CodingKeys, age, basedOn, bones (+26 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.04
Nodes (65): CrowdBodies, generated, library, .title, DirectLightMode, auto, exact, grouped (+57 more)

### Community 43 - "VSMTargets"
Cohesion: 0.12
Nodes (19): GPUVSMView, Kind, sphere, spot, sun, Light, .views, Float (+11 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (43): To do on the M4 Max, MaterialTextures, MTLCommandQueue, MTLDevice, MTLTexture, .empty, LoadOptions, PreparedScene (+35 more)

### Community 45 - "View"
Cohesion: 0.07
Nodes (62): E, .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body (+54 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (9): Blue Hemisphere, Green Vertical Plane, Indirect Global Illumination, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism (+1 more)

### Community 47 - "LumenScene"
Cohesion: 0.06
Nodes (32): Int8, .e, Baked, bricks, heights, GPULumenMeshSDF, GPULumenSDFInstance, LumenScene (+24 more)

### Community 48 - "AppDelegate"
Cohesion: 0.16
Nodes (9): NSApplication, NSApplicationDelegate, NSMenuItem, AppDelegate, Any, NSWindow, UndoManager, URL (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (18): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+10 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.11
Nodes (20): Build, Params, Float, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer, MTLComputePipelineState, MTLPrimitiveAccelerationStructureDescriptor (+12 more)

### Community 51 - "LumenGlobalSDF"
Cohesion: 0.13
Nodes (12): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Float, MTLBuffer, MTLDevice, MTLTexture (+4 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (41): SceneKind, area, buildings, .cameraFromScene, characters, city, cityNight, cornell (+33 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".xyz"
Cohesion: 0.09
Nodes (16): GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, Float, SIMD8, Void, FleshOptions (+8 more)

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
Nodes (43): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+35 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Surface.metal"
Cohesion: 0.04
Nodes (89): Material, bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow(), cloudShadowAt(), fetchHitVertices() (+81 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (20): device, VGBlas, attrs, pad0, pad1, pad2, triangles, tris (+12 more)

### Community 63 - "MeshData"
Cohesion: 0.15
Nodes (13): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (5): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Graphics Performance Testing, Direct Rendering Stress Test 32

### Community 65 - "FluidSystem"
Cohesion: 0.09
Nodes (27): .surfaceCapacity, Float, UInt32, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims (+19 more)

### Community 66 - "Gallery Showcase View"
Cohesion: 0.67
Nodes (4): Gallery Showcase View, Mechanical Design Language, Individual Item Pedestal Display Pattern, Steampunk Aesthetic

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "Int"
Cohesion: 0.03
Nodes (56): Metal3RenderPass, PrimitiveRefit, PrimitiveWork, .encoderCount, RenderPass, MTLAccelerationStructure, MTLAccelerationStructureCommandEncoder, MTLBuffer (+48 more)

### Community 73 - "CityPlan"
Cohesion: 0.07
Nodes (33): .name, Block, CityPlan, Edge, open, party, street, Lamp (+25 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.09
Nodes (21): GPUFluidParams, GPUFluidParticle, PhysicsWorld, .buckets, .cellSize, .kinematicRows, .params, .particleBuckets (+13 more)

### Community 75 - "simd"
Cohesion: 0.06
Nodes (3): Foundation, simd, MeshSimplifier

### Community 76 - "CharacterBase"
Cohesion: 0.11
Nodes (17): Character creator: handoff, Decisions (the user's), Deviations from the plan, and why, Open, Traps found, CharacterBase, Hand, Options (+9 more)

### Community 77 - "FoliageVoxels"
Cohesion: 0.25
Nodes (11): FoliageVoxels, Grid, Piece, Plant, Float, UInt32, BoxData, MTLCommandQueue (+3 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.06
Nodes (34): MTLRegion, MTLSparseTextureMappingMode, .isCancelled, LoadStep, .isCancelled, .materialBuffers, .data, Entry (+26 more)

### Community 79 - "FoliageTextures"
Cohesion: 0.07
Nodes (32): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+24 more)

### Community 80 - "KernelVariants"
Cohesion: 0.25
Nodes (14): Pipelines: `Pipelines.swift`, MTLFunctionConstantValues, MTLLibrary, finish, .function, KernelVariants, .count, AnyObject (+6 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.13
Nodes (12): Sendable, Job, .heading, LoadActivity, .onChange, LoadJob, Snapshot, .isIdle (+4 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (51): int4, lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo() (+43 more)

### Community 84 - "uint"
Cohesion: 0.17
Nodes (25): boxCandidate(), candidate(), candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed() (+17 more)

### Community 85 - "VirtualBLAS"
Cohesion: 0.14
Nodes (20): Where things are, Built, CutInput, Entry, Float, MTLAccelerationStructure, MTLBuffer, MTLCommandQueue (+12 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.04
Nodes (33): AnyObject, base, interior, BuildingEditorHost, BuildingEditorModel, .def, .inWorkshop, .isBuiltIn (+25 more)

### Community 88 - "Capabilities"
Cohesion: 0.22
Nodes (6): Capabilities: `Capabilities.swift`, Capabilities, MTLDevice, CapabilitiesTests, .none, Void

### Community 89 - "Foliage"
Cohesion: 0.04
Nodes (61): Card, Level, Mesh, Plant, RawRepresentable, Skeleton, Float, Age (+53 more)

### Community 90 - "Images"
Cohesion: 0.15
Nodes (5): 6. Math, Modes, Images, SkySettings, .cloudsShown

### Community 91 - "SurfaceKind"
Cohesion: 0.07
Nodes (26): Float, MaterialDef, Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete (+18 more)

### Community 92 - "Where things are"
Cohesion: 0.12
Nodes (15): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, Cover, Habitat, Ramp, Float (+7 more)

### Community 93 - "Upscaler"
Cohesion: 0.19
Nodes (9): AnyObject, Float, MTLCommandBuffer, MTLDevice, MTLTexture, SIMD2, UInt32, Upscaler (+1 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (52): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+44 more)

### Community 95 - "FluidTests"
Cohesion: 0.20
Nodes (5): FluidTests, Float, MTLCommandQueue, MTLDevice, Void

### Community 96 - "quatRotate"
Cohesion: 0.05
Nodes (56): Phases, CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot (+48 more)

### Community 97 - "PhysicsTests"
Cohesion: 0.14
Nodes (7): GPUPhysicsGrab, PhysicsTests, Float, MTLCommandQueue, MTLDevice, SDFShape, Void

### Community 98 - "MuscleTests"
Cohesion: 0.08
Nodes (13): centre, GPUPhysicsShape, Cloth, PhysicsJoint, PhysicsJointKind, ball, hinge, Float (+5 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (47): Building, .triangleCount, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail (+39 more)

### Community 100 - "float3"
Cohesion: 0.10
Nodes (40): float3, thread, physAdd(), physAddFound(), physAgree(), physArea(), physBetween(), physBox() (+32 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (14): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+6 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (19): ArraySlice, GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, Float (+11 more)

### Community 103 - "uint4"
Cohesion: 0.04
Nodes (49): uint4, PhysicsCloth, grid, previous, PhysicsHairParams, air, counts, gravity (+41 more)

### Community 104 - "Bool"
Cohesion: 0.12
Nodes (15): PlanDoor, PlanRoom, .area, StoreyPlanner, Float, SIMD2, SplitMix64, Rect (+7 more)

### Community 105 - "CaseIterable"
Cohesion: 0.03
Nodes (66): CaseIterable, Tab, facade, floors, furnish, look, massing, rooms (+58 more)

### Community 106 - "SettingsTable"
Cohesion: 0.07
Nodes (32): on, Kind, arrays, block, clusters, skip, virtual, Control (+24 more)

### Community 107 - ".trees"
Cohesion: 0.24
Nodes (4): Flora, Placement, UInt32, UInt16

### Community 108 - "LotRef"
Cohesion: 0.08
Nodes (27): Encodable, JSONEncoder, .currentOverride, .currentRef, .fingerprint, BuildingStore, .encoder, .folder (+19 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 110 - "CharacterParam"
Cohesion: 0.10
Nodes (14): Group, CharacterParam, CharacterParams, Group, bones, macro, shape, skin (+6 more)

### Community 111 - "CurveEditor"
Cohesion: 0.10
Nodes (22): DragGesture, EnvironmentKey, CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey (+14 more)

### Community 112 - "WorldTile"
Cohesion: 0.11
Nodes (20): .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light, Data (+12 more)

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (40): device, float2, float3, float4, thread, uint, uint4, sdfEval() (+32 more)

### Community 114 - "Metal"
Cohesion: 0.10
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysPoints"
Cohesion: 0.12
Nodes (17): physContactPush(), PhysicsContact, anchorA, anchorB, lambda, normal, PhysPoints, pa (+9 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.15
Nodes (16): BuildingAssembler, Cell, .center, .width, Opening, Float, SIMD2, Void (+8 more)

### Community 118 - "Interior"
Cohesion: 0.13
Nodes (23): Door, Prop, Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder (+15 more)

### Community 119 - "RendererController"
Cohesion: 0.10
Nodes (16): .buildingPlan, .buildingStats, .cameraPosition, .walker, Float, .characterStats, .plantStats, RendererController (+8 more)

### Community 120 - ".meshes"
Cohesion: 0.16
Nodes (16): MTLDevice, Cluster, Group, .isRoot, Data, Float, SIMD2, UInt32 (+8 more)

### Community 121 - "Flora"
Cohesion: 0.11
Nodes (14): Flora, .name, Placed, assembly, flat, Prepared, boxes, flat (+6 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (14): CodingKey, Keys, hi, lo, Foliage.Curve, Key, crown, linear (+6 more)

### Community 125 - "GLTFModel"
Cohesion: 0.13
Nodes (19): CustomStringConvertible, GLTFError, .description, invalid, unsupported, GLTFModel, .bounds, .triangleCount (+11 more)

### Community 126 - ".buildWorld"
Cohesion: 0.10
Nodes (16): SurfaceMaterial, .uvScale, Prop, Camera, .forward, .right, .up, Float (+8 more)

### Community 127 - "SDFShape"
Cohesion: 0.13
Nodes (22): Node, .transform, Op, intersect, subtract, union, Primitive, box (+14 more)

### Community 128 - "Raster.metal"
Cohesion: 0.21
Nodes (28): depth2d, atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), constant, device, float3, kernel (+20 more)

### Community 129 - "RenderSettings"
Cohesion: 0.05
Nodes (44): Bound, 4. CPU↔GPU data layout, Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, Settings: `SettingsTable.swift`, Things that are not structures yet, Where new code belongs, The pass, The pass after a feature (+36 more)

### Community 130 - ".building"
Cohesion: 0.40
Nodes (4): Float, SIMD2, Walker, WalkerTests

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.09
Nodes (48): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+40 more)

### Community 132 - "Config"
Cohesion: 0.15
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, Void

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (46): boneAngle(), bucketPhase(), coverLean(), meanGust(), constant, device, float3, float4 (+38 more)

### Community 134 - "PlantEditorTests"
Cohesion: 0.12
Nodes (9): PlantMutate, Root, SplitMix64, UInt64, Host, PlantEditorTests, Root, URL (+1 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+4 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (36): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+28 more)

### Community 138 - "RasterVGParams"
Cohesion: 0.11
Nodes (18): float4, RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam (+10 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.18
Nodes (13): .megabytes, Entry, Float, MTLAccelerationStructure, MTLAccelerationStructureUsage, MTLBuffer, MTLCommandQueue, MTLDevice (+5 more)

### Community 140 - "VGStreamer"
Cohesion: 0.13
Nodes (11): BuddyAllocator, Group, Float, MTLBuffer, MTLDevice, Set, UInt32, VGStreamer (+3 more)

### Community 141 - "FluidSurface.metal"
Cohesion: 0.12
Nodes (33): BlueNoise, .cacheURL, SplitMix64, Float, UInt64, URL, fluidCorner(), FluidSurface (+25 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.23
Nodes (21): RasterClusterMeshOut, constant, device, kernel, read, texture2d, thread, uint (+13 more)

### Community 143 - "geometryDebugKernel"
Cohesion: 0.21
Nodes (24): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+16 more)

### Community 144 - ".env"
Cohesion: 0.11
Nodes (10): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh` (+2 more)

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (17): CALayer, NSDraggingInfo, NSDragOperation, NSObjectProtocol, InputHandler, RenderView, .acceptsFirstResponder, CGRect (+9 more)

### Community 146 - "Map"
Cohesion: 0.10
Nodes (23): Map, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, MTL4ComputeCommandEncoder, MTLAccelerationStructure (+15 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (22): atomic_uint, VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY (+14 more)

### Community 148 - ".load"
Cohesion: 0.20
Nodes (6): Failure, ShaderSource, URL, Substring, ShaderSourceTests, URL

### Community 149 - "Hit"
Cohesion: 0.25
Nodes (8): Hit, barycentrics, cluster, hit, instance, part, primitive, intersectClosest()

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (4): Combine, Element, QuartzCore, Array

### Community 151 - "MeshBuilder"
Cohesion: 0.15
Nodes (12): OptionSet, Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount (+4 more)

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (31): Where things are, ComputePass, MTLComputePipelineState, Step, FluidGPU, .summary, Steps, MTLBuffer (+23 more)

### Community 153 - "Int32"
Cohesion: 0.36
Nodes (6): Int32, LocalIds, MeshClusterizer, Float, UInt32, UnsafeBufferPointer

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (16): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+8 more)

### Community 155 - "Where things are"
Cohesion: 0.11
Nodes (13): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, Where things are, P, BuildingMutate (+5 more)

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (16): Side, Furnisher, FurnishPalette, Light, Prefer, any, away, corner (+8 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (6): CGSize, FloorPlan, .height, BuildingPlanTests, Float, SIMD2

### Community 158 - "DebugPanel"
Cohesion: 0.10
Nodes (14): NSRect, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, CFTimeInterval, Notification (+6 more)

### Community 159 - "FBXFile"
Cohesion: 0.08
Nodes (36): Compression, IteratorProtocol, Sequence, simd_quatd, Children, Connection, Contents, FBXArrayElement (+28 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (18): instance_acceleration_structure, RTPart, TraceScene, clusterInstance, clusters, cutouts, indices, meshes (+10 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.18
Nodes (21): geometry_type, intersection_params, intersection_type, anyHit(), assumeCurves(), assumeCurveShape(), closestDistance(), closestHit() (+13 more)

### Community 162 - "AppKit"
Cohesion: 0.12
Nodes (5): AppKit, CoreGraphics, ImageIO, Headless, UniformTypeIdentifiers

### Community 163 - "Lift"
Cohesion: 0.10
Nodes (21): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Float, SIMD2 (+13 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "CameraTrack"
Cohesion: 0.13
Nodes (7): CameraTrack, .duration, Key, Float, ShowcaseLook, Float, Void

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (7): uint3, uint4, RTVoxels, dims, lo, offsets, voxelDims()

### Community 167 - ".buildGallery"
Cohesion: 0.10
Nodes (5): SplitMix64, UInt64, URL, MeshGeometry, SDFTests

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (33): constant, device, float4, kernel, uint, vgBoxesKernel(), VGCluster, childGroup (+25 more)

### Community 169 - "CPU (Swift) practices for MetalRenderer"
Cohesion: 0.10
Nodes (16): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+8 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (5): Hash, .value, PlantGoldenTests, Float, T

### Community 171 - "CharacterLibrary"
Cohesion: 0.13
Nodes (14): CacheFile, Data, URL, CharacterKit, Data, UInt32, URL, BlobReader (+6 more)

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (22): float3, Light, read, SCENE_ACCEL, texture2d, thread, uint2, write (+14 more)

### Community 173 - "Post.metal"
Cohesion: 0.29
Nodes (21): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+13 more)

### Community 174 - "Metal3Pass"
Cohesion: 0.05
Nodes (32): MTL4InstanceAccelerationStructureDescriptor, MTLCounterSampleBuffer, MTLCounterSet, MTLFence, MTLRenderPassColorAttachmentDescriptor, MTLRenderPassDepthAttachmentDescriptor, MTLTimestamp, Metal3Frame (+24 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.16
Nodes (18): Color, GraphicsContext, FloorPlanView, .body, .help, .picked, .status, .storeys (+10 more)

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

### Community 180 - "uint"
Cohesion: 0.32
Nodes (16): constant, device, float4, kernel, uint, vertex, vsmAllocKernel(), vsmChunksKernel() (+8 more)

### Community 181 - "FleshFigure"
Cohesion: 0.11
Nodes (17): GPUSoftVertex, .cells, Flesh, MuscleSpec, Side, back, front, out (+9 more)

### Community 182 - ".writeDescriptors"
Cohesion: 0.23
Nodes (6): Tests, float3x3, RTPart, Float, UInt32, Wind

### Community 183 - "WindFrame"
Cohesion: 0.16
Nodes (10): MTLComputePipelineState, PlantKey, Float, SIMD8, WindFrame, .plantKey, .poseKey, PlantTracingTests (+2 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SIMD3"
Cohesion: 0.06
Nodes (33): Float16, simd_double3x3, Atmosphere, Float, GPURasterMesh, .worldToView, PhysicsCandidate, .middle (+25 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "GPULight"
Cohesion: 0.30
Nodes (8): GPULight, GPULightTreeNode, LightTree, .byteCount, Float, Range, SIMD2, UInt32

### Community 190 - "PhysicsBody"
Cohesion: 0.08
Nodes (38): physAcross(), physAnchorTurnWeight(), physConj(), physContactKick(), physDampJoint(), physHold(), PhysicsBody, angular (+30 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (11): uint4, VSMInstance, corners, indices, meshIndex, pages, view, w (+3 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.28
Nodes (8): ColliderGrid, Input, Moving, Float, SIMD2, Walker, .eyePosition, .height

### Community 193 - "BuildingEditorPanel"
Cohesion: 0.20
Nodes (8): NSWindowDelegate, BuildingEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 194 - ".build"
Cohesion: 0.40
Nodes (5): CharacterBuilder, CharacterShape, MacroRig, Float, simd_float3x3

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (10): atomic_uint, RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount (+2 more)

### Community 196 - "SplitMix"
Cohesion: 0.47
Nodes (3): SplitMix, Float, UInt64

### Community 197 - "LightKind"
Cohesion: 0.20
Nodes (10): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+2 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 199 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.25
Nodes (8): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, GPU (Metal / MSL) practices for MetalRenderer, float2, rtCutout()

### Community 200 - "RasterInstance"
Cohesion: 0.14
Nodes (14): float4, fragment, rasterFragment(), RasterInstance, corners, indices, w, x (+6 more)

### Community 201 - "RagdollTests"
Cohesion: 0.16
Nodes (8): GPUPhysicsJoint, PhysicsJoint, RagdollTests, Float, MTLCommandQueue, MTLDevice, PhysicsJoint, Void

### Community 202 - "FurnitureItem"
Cohesion: 0.35
Nodes (4): FurnitureItem, .collisionBoxes, Float, SplitMix64

### Community 203 - "String"
Cohesion: 0.05
Nodes (27): MTLBlitCommandEncoder, MTLCommandEncoder, MTLRenderPassDescriptor, NSColor, CatalogRegistry, T, Section, NSCoder (+19 more)

### Community 204 - ".encoder"
Cohesion: 0.24
Nodes (3): MTLStages, MTL4ComputeCommandEncoder, MTLBarrierScope

### Community 205 - ".stages"
Cohesion: 0.17
Nodes (13): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Float, MTLBuffer, MTLComputePipelineState, MTLDevice (+5 more)

### Community 206 - "PostParams"
Cohesion: 0.17
Nodes (12): Material, albedo, emission, params, textures, uint4, PostParams, bloom (+4 more)

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
Nodes (41): float4, PhysicsFleshFibre, compliance, g, muscle, pad0, pad1, PhysicsFleshPin (+33 more)

### Community 211 - "PhysicsPair"
Cohesion: 0.40
Nodes (5): PhysicsPair, contacts, link, pad, partner

### Community 212 - "PhysicsPoseParams"
Cohesion: 0.40
Nodes (5): PhysicsPoseParams, bodies, descriptorStride, pad0, pad1

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 219 - "traceKernel"
Cohesion: 0.10
Nodes (51): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+43 more)

### Community 220 - "LightTreeTests"
Cohesion: 0.29
Nodes (4): LightTreeTests, Float, StaticString, UInt

### Community 221 - "CharacterEditorPanel"
Cohesion: 0.24
Nodes (7): CharacterEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 222 - "SceneShading"
Cohesion: 0.15
Nodes (13): texture2d_array, SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky (+5 more)

### Community 223 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 224 - "float4"
Cohesion: 0.18
Nodes (11): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+3 more)

### Community 226 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (6): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests, UInt32

### Community 227 - "RenderThread"
Cohesion: 0.20
Nodes (4): Notification, RenderThread, Thread, Void

### Community 228 - "Buffer"
Cohesion: 0.22
Nodes (8): MTL4CommandBuffer, MTL4UpdateSparseTextureMappingOperation, Buffer, mappings, metal3, metal4, MTLHeap, UInt64

### Community 229 - "Key"
Cohesion: 0.23
Nodes (6): Hashable, Key, PipelineCache, .count, MTLComputePipelineState, Value

### Community 231 - ".commit"
Cohesion: 0.38
Nodes (6): FrameTimes, CFTimeInterval, FeedbackCollector, CAMetalDrawable, CFTimeInterval, Void

### Community 232 - "SceneSettings"
Cohesion: 0.08
Nodes (12): Scene kinds: `SceneKind` in `Settings.swift`, SceneSettings, SIMD2, URL, ForestTests, SceneBuffersTests, Float, MeshGeometry (+4 more)

### Community 233 - ".keep"
Cohesion: 0.28
Nodes (4): MTLAccelerationStructure, MTLAllocation, MTLTexture, Range

### Community 234 - "RenderPass4"
Cohesion: 0.18
Nodes (6): MTL4RenderCommandEncoder, RenderPass4, MTLBuffer, MTLDepthStencilState, MTLRenderPipelineState, UnsafeRawPointer

### Community 235 - ".updatePrimitives"
Cohesion: 0.25
Nodes (4): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, MTLCommandBuffer

### Community 236 - "Double"
Cohesion: 0.13
Nodes (16): Double, World, .anchorTile, .start, Block, City, Ground, Highway (+8 more)

### Community 237 - "WorldPlace"
Cohesion: 0.52
Nodes (4): Float, SIMD2, WorldPlace, .anchor

### Community 238 - "Particles"
Cohesion: 0.33
Nodes (6): Particles, bubbles, dust, embers, none, runes

### Community 239 - "XCTestCase"
Cohesion: 0.27
Nodes (4): PipelineCacheTests, UInt32, VGStreamerTests, XCTestCase

### Community 240 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PlantEditorPanel"
Cohesion: 0.19
Nodes (8): NSObject, PlantEditorPanel, .isVisible, .wasVisible, Notification, NSPanel, NSWindow, UndoManager

### Community 243 - "Core"
Cohesion: 0.22
Nodes (9): Core, .all, .stairPlan, Mode, backCore, frontCore, none, sideLeft (+1 more)

### Community 245 - "Region"
Cohesion: 0.25
Nodes (8): Region, arm, foot, hand, head, leg, neck, trunk

### Community 246 - "LoadingOverlay"
Cohesion: 0.10
Nodes (17): NSFont, NSPoint, NSStackView, NSView, LoadingOverlay, .isEnabled, Model, heading (+9 more)

### Community 247 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

### Community 248 - "DebugInfo"
Cohesion: 0.25
Nodes (7): DebugInfo, Float, VirtualGeometry, blas, clusters, off, .triangles

### Community 249 - "RasterScene"
Cohesion: 0.22
Nodes (6): RasterScene, .megabytes, RasterTargets, MTLBuffer, MTLDevice, MTLTexture

### Community 250 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

### Community 251 - "WallGrid"
Cohesion: 0.29
Nodes (7): WallGrid, .alongX, .hi, .line, .lines, .lo, .middles

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "Types.metal"
Cohesion: 0.25
Nodes (7): MaterialTexture, t, texture2d, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 254 - "Heavens"
Cohesion: 0.33
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 255 - "Measuring MetalRenderer"
Cohesion: 0.29
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 256 - "clusterWalk"
Cohesion: 0.53
Nodes (6): clusterWalk(), float3, octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 260 - "CharacterMorphs"
Cohesion: 0.13
Nodes (22): Kind, furniture, glass, solid, stair, Bump, CharacterMorphs, Coordinates (+14 more)

### Community 261 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 262 - ".capture"
Cohesion: 0.50
Nodes (3): MTLBuffer, MTLDevice, MTLTexture

## Knowledge Gaps
- **1796 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1791 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2416 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **21 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Codable`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `CharacterEditorModel`, `LightTable`, `float4x4`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `.shared`, `RadianceCascades`, `GPUTypes.swift`, `GeneratedCache`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `View`, `LumenScene`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `.xyz`, `MuscleAtlas`, `FluidSystem`, `CityPlan`, `PhysicsWorld`, `CharacterBase`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `Foliage`, `Images`, `SurfaceKind`, `Where things are`, `Upscaler`, `FluidTests`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Bool`, `CaseIterable`, `SettingsTable`, `.trees`, `LotRef`, `EnvVariable`, `CharacterParam`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `RendererController`, `.meshes`, `Flora`, `GLTFModel`, `.buildWorld`, `SDFShape`, `RenderSettings`, `.building`, `Config`, `PlantEditorTests`, `Benchmark`, `RoomType`, `VoxelLOD`, `VGStreamer`, `FluidSurface.metal`, `Map`, `QuartzCore`, `MeshBuilder`, `Pipelines`, `Int32`, `Curve`, `Where things are`, `Furnisher`, `FloorPlan`, `DebugPanel`, `FBXFile`, `Lift`, `.buildGallery`, `Metal3Pass`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `.writeDescriptors`, `WindFrame`, `FoliageRuntimeTests`, `SIMD3`, `Role`, `GPULight`, `ColliderGrid`, `LightKind`, `RagdollTests`, `FurnitureItem`, `String`, `.stages`, `Terrain`, `StressSceneTests`, `Key`, `.commit`, `SceneSettings`, `.keep`, `RenderPass4`, `Double`, `WorldPlace`, `XCTestCase`, `LoadingOverlay`, `DebugInfo`, `RasterScene`, `CharacterMorphs`, `.dispatchThreadgroups`?**
  _High betweenness centrality (0.275) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `Codable`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `translate`, `CharacterEditorModel`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `.shared`, `GeneratedCache`, `CharacterDNA`, `SettingsTable.swift`, `SceneBuffers`, `View`, `VirtualGeometry`, `SceneKind`, `MuscleAtlas`, `FluidSystem`, `Int`, `CityPlan`, `CharacterBase`, `FoliageVoxels`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `Capabilities`, `Foliage`, `Images`, `SurfaceKind`, `Where things are`, `Upscaler`, `FluidTests`, `Bool`, `CaseIterable`, `SettingsTable`, `LotRef`, `EnvVariable`, `CharacterParam`, `CurveEditor`, `WorldTile`, `RendererController`, `.meshes`, `Flora`, `Key`, `GLTFModel`, `.buildWorld`, `RenderSettings`, `Config`, `PlantEditorTests`, `Kind`, `Benchmark`, `RoomType`, `VGStreamer`, `.env`, `Map`, `.load`, `Pipelines`, `Curve`, `Where things are`, `FloorPlan`, `DebugPanel`, `FBXFile`, `Lift`, `CameraTrack`, `.add`, `CharacterLibrary`, `Metal3Pass`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `SIMD3`, `.build`, `.encoder`, `KernelVariantsTests`, `Buffer`, `.commit`, `SceneSettings`, `.updatePrimitives`, `Double`, `Clip`, `.mark`, `LoadingOverlay`, `Op`, `DebugInfo`, `CharacterMorphs`, `Kind`, `.worldView`?**
  _High betweenness centrality (0.153) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `Codable`, `.simplify`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `CharacterEditorModel`, `float4x4`, `RasterClusters`, `SettingsPanel`, `Renderer`, `.shared`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `View`, `LumenScene`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `.xyz`, `MuscleAtlas`, `Int`, `CityPlan`, `PhysicsWorld`, `CharacterBase`, `FoliageVoxels`, `TextureStreamer`, `FoliageTextures`, `KernelVariants`, `LoadActivity`, `VirtualBLAS`, `BuildingEditorModel`, `Foliage`, `Images`, `SurfaceKind`, `Where things are`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `SettingsTable`, `LotRef`, `EnvVariable`, `CurveEditor`, `WorldTile`, `BuildingAssembler`, `Interior`, `RendererController`, `.meshes`, `Flora`, `.buildWorld`, `SDFShape`, `RenderSettings`, `Config`, `Benchmark`, `RoomType`, `VoxelLOD`, `VGStreamer`, `.env`, `RenderView`, `Map`, `.load`, `MeshBuilder`, `Pipelines`, `Int32`, `Curve`, `Where things are`, `Furnisher`, `FloorPlan`, `DebugPanel`, `FBXFile`, `Lift`, `CharacterLibrary`, `Metal3Pass`, `PlantParam`, `FleshFigure`, `.writeDescriptors`, `WindFrame`, `FoliageRuntimeTests`, `SIMD3`, `ColliderGrid`, `BuildingEditorPanel`, `.build`, `LightKind`, `RagdollTests`, `String`, `.encoder`, `LightTreeTests`, `CharacterEditorPanel`, `RenderThread`, `Key`, `.commit`, `SceneSettings`, `Double`, `XCTestCase`, `PlantEditorPanel`, `Core`, `LoadingOverlay`, `DebugInfo`, `RasterScene`, `WallGrid`, `Heavens`, `.capture`?**
  _High betweenness centrality (0.121) - this node is a cross-community bridge._
- **Are the 52 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 52 INFERRED edges - model-reasoned connections that need verification._
- **Are the 35 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.chooseInterior()`) actually correct?**
  _`Scene` has 35 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1796 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.03494335122242099 - nodes in this community are weakly interconnected._