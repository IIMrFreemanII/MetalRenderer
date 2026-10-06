# Graph Report - MetalGI  (2026-10-07)

## Corpus Check
- 200 files · ~1,163,739 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 22 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 4)

## Summary
- 5816 nodes · 17386 edges · 224 communities (180 shown, 44 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 2571 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `0d1cc14c`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- .xyz
- .part
- .simplify
- VGStreamer
- evalcommon.py
- SettingsTable
- RenderView
- rcTraceMergeKernel
- FramePlan
- GPUProfiler
- Metal4Frame
- translate
- Float
- roundToHalf
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
- SettingsTableTests
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
- SettingsTable.swift
- VSMTargets
- SceneBuffers
- regirBuildKernel
- 3D Rendered Scene with Geometric Primitives
- LumenScene
- AppDelegate
- .meshes
- FBXReader.swift
- DebugPanel
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- String
- FogParams
- Shaders.metal
- VGBlas
- SceneShading
- Direct Rendering Stress Test 32
- SIMD3
- Gallery Showcase View
- Geometric Objects (Box, Cube, Sphere)
- graphify Knowledge Graph (graphify-out/)
- Package.swift
- Character Reference Overview Gallery
- Direct Illumination Mechanism
- FBXFile
- CityPlan
- Int32
- simd
- RenderPass
- FoliageVoxels
- VirtualBLAS
- Int
- Pipelines
- ab.sh
- Hair.metal
- FBXError
- Ray
- EmissiveTriangle
- .icosphere
- Double
- RendererController
- Float
- CaseIterable
- SurfaceKind
- SkyParams
- Upscaler
- megaLightsSampleKernel
- .buildStress
- Crowd.metal
- .length
- Metal3Pass
- Footprint
- float3
- ClusterBox
- SIMD4
- uint4
- Building
- BuildingStyle
- EnvVariable
- Types.metal
- PostParams
- MeshData
- Species
- .draw
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- BuildingAssembler
- lumenTraceKernel
- SplitMix64
- Benchmark
- Foliage
- same.sh
- .commit
- baseline.sh
- Map
- CityTests
- Primitive
- Raster.metal
- RagdollTests
- Slot
- lumenCardRadiosityKernel
- RasterClusters
- PlantWind
- .write
- Chunk
- LumenCards
- .planFrame
- RenderPass4
- LumenGlobalSDF
- HairTests
- KernelVariantsTests
- RasterClusters.metal
- LightKind
- SettingsStore
- Proving a refactor changed nothing
- LayerSurface
- VSMCounters
- Camera
- Hit
- QuartzCore
- XCTestCase
- ComputePass
- PlantTracing
- Crown
- Buffer
- Phyllotaxis
- CameraTrack
- VirtualTracing
- physCollide
- TraceScene
- Intersect.metal
- ImageIO
- RasterVGParams
- related.sh
- SDFShape
- RTVoxels
- HairBSDF
- VGParams
- Float
- Shape
- VSM.metal
- StressSceneTests
- RasterScene
- .withUnsafeBufferPointer
- VSMView
- Section
- VSMClusterArgs
- VSMScene
- .stages
- RendererError
- SceneSettings
- RasterInstance
- VSMParams
- FoliageRuntimeTests
- uint
- RasterParams
- .preset
- SDFBuffers
- PhysicsParams
- VSMInstance
- PrimitiveWork
- SplitMix
- PhysicsJoint
- RasterCounters
- LightTreeNode
- .int
- SDFBox
- RenderThread
- DebugInfo
- Metal-only tracer: handoff to the M4 Max (2026-10-06)
- Bool
- PhysicsGrab
- PhysPush
- RasterTargets
- .end
- PhysicsConstraint
- PhysicsGroup
- PhysicsHairVertex
- PhysicsPair
- PhysicsPoseParams
- VGRasterInstance
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- .generate
- vsmFragment

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 320 edges
2. `Scene` - 271 edges
3. `Renderer` - 253 edges
4. `PhysicsWorld` - 190 edges
5. `Kernel` - 120 edges
6. `SIMD4` - 119 edges
7. `.length` - 118 edges
8. `Benchmark` - 105 edges
9. `simd` - 98 edges
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

## Communities (224 total, 44 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (43): GLTFModel, .triangleCount, Light, GPUEmissiveTriangle, meshLights, Assembly, Bone, BorrowedLight (+35 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.05
Nodes (42): LoadError, unreadable, Accessor, AnyDecodable, Asset, Buffer, BufferView, Document (+34 more)

### Community 3 - "RenderSettings"
Cohesion: 0.18
Nodes (26): CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel, FogSettings, .windDirection, .windSpeed (+18 more)

### Community 4 - "Lights.metal"
Cohesion: 0.06
Nodes (64): clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), lightSpecular() (+56 more)

### Community 5 - ".xyz"
Cohesion: 0.16
Nodes (3): GPUPhysicsBody, GPUPhysicsContact, PhysicsMath

### Community 6 - ".part"
Cohesion: 0.21
Nodes (9): CharacterImporter, Clip, .duration, .loopKeys, concurrently(), Skeleton, .bindPositions, .bindRotations (+1 more)

### Community 8 - "VGStreamer"
Cohesion: 0.13
Nodes (6): BuddyAllocator, Group, VGStreamer, .groupCount, .isSettled, .residentMB

### Community 9 - "evalcommon.py"
Cohesion: 0.06
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 10 - "SettingsTable"
Cohesion: 0.09
Nodes (22): Control, checkbox, custom, popup, slider, Custom, clearModels, denoiserCaption (+14 more)

### Community 11 - "RenderView"
Cohesion: 0.08
Nodes (3): InputHandler, RenderView, .acceptsFirstResponder

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.11
Nodes (18): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Performance in MetalRenderer, The loop, rcClearAmbientKernel(), rcEvalSH(), RCParams (+10 more)

### Community 13 - "FramePlan"
Cohesion: 0.20
Nodes (13): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, Things that are not structures yet, Where new code belongs, ComputeStage, CompositeInputs, FramePlan, .prev (+5 more)

### Community 14 - "GPUProfiler"
Cohesion: 0.11
Nodes (3): Metal3Frame, GPUProfiler, .passProfilingSupported

### Community 16 - "translate"
Cohesion: 0.18
Nodes (11): Scene kinds: `SceneKind` in `Settings.swift`, translate(), FogVolume, .gpu, LightPose, Kit, RagdollShapes, Stand (+3 more)

### Community 17 - "Float"
Cohesion: 0.10
Nodes (12): GPUPhysicsShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsShapeKind, box, capsule, plane (+4 more)

### Community 18 - "roundToHalf"
Cohesion: 0.13
Nodes (19): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer (+11 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (24): fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel(), fogMedium() (+16 more)

### Community 20 - "Sky.metal"
Cohesion: 0.14
Nodes (26): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+18 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (60): makeRay(), pathTraceKernel(), PathTraceParams, bounds, config, samples, ptEval(), PTFog (+52 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (4): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount

### Community 23 - "TextureStreamer"
Cohesion: 0.08
Nodes (12): Entry, Level, SparseMapping, TextureStreamer, .details, .placement, .residentLevels, .summary (+4 more)

### Community 24 - "VirtualGeometry"
Cohesion: 0.11
Nodes (12): Build, Params, VGPipelines, VirtualGeometry, .clusterCount, .groupCount, .meshCount, .pool (+4 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (32): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+24 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.14
Nodes (9): GPUJoint, .parent, GPUSkinVertex, Level, .triangleCount, Part, SkinnedCharacter, .triangleCount (+1 more)

### Community 27 - "geometryDebugKernel"
Cohesion: 0.12
Nodes (22): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), geometryDebugKernel() (+14 more)

### Community 28 - "Kernel"
Cohesion: 0.02
Nodes (103): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+95 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (8): Settings: `SettingsTable.swift`, Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (43): 8. Pipelines and resources, SkyImage, GPUSkyParams, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode (+35 more)

### Community 31 - "SettingsTableTests"
Cohesion: 0.10
Nodes (9): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table, SettingsEnv, ForestTests (+1 more)

### Community 32 - "traceKernel"
Cohesion: 0.10
Nodes (26): 3. Occupancy and registers: the default suspect for big kernels, groupMask(), cosineSampleHemisphere(), laineKarrasPermutation(), luminance(), makeSampler(), nestedUniformScramble(), owenSobol2() (+18 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.12
Nodes (18): emptyReservoir(), packReservoir(), Reservoir, element, M, uv, visible, W (+10 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (31): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+23 more)

### Community 35 - "RadianceCascades"
Cohesion: 0.18
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "GPUTypes.swift"
Cohesion: 0.10
Nodes (28): GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUInstanceData, GPUJointMatrix, GPUMegaLightsParams, GPUPathTraceParams, GPUPhysicsConstraint (+20 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "SectionFile"
Cohesion: 0.16
Nodes (5): CryptoKit, GeneratedCache, SectionFile, Writer, Section

### Community 39 - "Physics.metal"
Cohesion: 0.17
Nodes (39): physCell(), physColourPairs(), physColoursAround(), physDistance2(), physFlat(), physHash(), physicsClearKernel(), physicsClothMeshKernel() (+31 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Mesh"
Cohesion: 0.15
Nodes (10): LeafAnchor, LeafShape, blade, kite, needle, Mesh, .leafTriangles, .triangles (+2 more)

### Community 42 - "SettingsTable.swift"
Cohesion: 0.05
Nodes (49): DirectLightMode, auto, exact, grouped, megalights, restir, .title, GIMode (+41 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (16): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Kind, sphere, spot (+8 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.07
Nodes (19): LoadOptions, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, InstanceBlock, .held, MeshBlock, .indexOffset (+11 more)

### Community 45 - "regirBuildKernel"
Cohesion: 0.12
Nodes (17): regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup(), RegirParams (+9 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (8): Blue Hemisphere, Green Vertical Plane, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism, Yellow Cube

### Community 47 - "LumenScene"
Cohesion: 0.14
Nodes (7): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source

### Community 49 - ".meshes"
Cohesion: 0.11
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - "FBXReader.swift"
Cohesion: 0.19
Nodes (7): Compression, Contents, FBXArrayElement, unsupported, Float, Int64, MappedFile

### Community 52 - "SceneKind"
Cohesion: 0.06
Nodes (34): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+26 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.08
Nodes (14): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsParams, GPUPhysicsParticle, Cloth, PhysicsWorld (+6 more)

### Community 55 - "Color Bleeding from Walls to Objects"
Cohesion: 0.40
Nodes (6): Color Bleeding from Walls to Objects, Direct and Indirect Illumination Effects, Geometric Primitives (Cylinder, Cube, Sphere, Rectangular Blocks), Global Illumination Reference Scene, Primary Light Source, Varied Material Surfaces and Reflectivity

### Community 56 - "3D Graphics Stress Test Scene"
Cohesion: 0.33
Nodes (5): Albedo Reference Image 1.5x, Color Palette Distribution, Geometric Shapes, 3D Spatial Layout, 3D Graphics Stress Test Scene

### Community 57 - "Direct Lighting Reference Render"
Cohesion: 0.40
Nodes (5): Geometric Complexity, Lighting Quality and Shadows, Material Properties and Colors, Direct Lighting Reference Render, Rendering Stress Test

### Community 59 - "String"
Cohesion: 0.05
Nodes (21): Capabilities: `Capabilities.swift`, FrameRecord, Launch, Capabilities, .summary, Frame, Backend, auto (+13 more)

### Community 60 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (77): glassKernel(), glassReflection(), reflectionHitRadiance(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow() (+69 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (19): VGBlas, attrs, pad0, pad1, pad2, triangles, tris, VGClusterView (+11 more)

### Community 63 - "SceneShading"
Cohesion: 0.15
Nodes (12): SceneShading, cloudShadow, emissive, feedback, materials, minLod, sky, skyParams (+4 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (4): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Direct Rendering Stress Test 32

### Community 65 - "SIMD3"
Cohesion: 0.08
Nodes (20): Atmosphere, AABB, .area, .centroid, .isEmpty, .bounds, Baked, bricks (+12 more)

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "FBXFile"
Cohesion: 0.23
Nodes (5): Children, Connection, FBXFile, .topLevel, Node

### Community 73 - "CityPlan"
Cohesion: 0.08
Nodes (29): .area, Block, CityPlan, Edge, open, party, street, Lamp (+21 more)

### Community 74 - "Int32"
Cohesion: 0.41
Nodes (3): Int32, LocalIds, MeshClusterizer

### Community 77 - "FoliageVoxels"
Cohesion: 0.47
Nodes (4): FoliageVoxels, Grid, Piece, Plant

### Community 78 - "VirtualBLAS"
Cohesion: 0.05
Nodes (24): World, .anchorTile, .start, WorldPlace, .anchor, Built, CutInput, Entry (+16 more)

### Community 79 - "Int"
Cohesion: 0.10
Nodes (11): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+3 more)

### Community 80 - "Pipelines"
Cohesion: 0.19
Nodes (9): Pipelines: `Pipelines.swift`, .function, KernelVariants, .count, Key, Pipelines, .lumen, .rc (+1 more)

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "Hair.metal"
Cohesion: 0.10
Nodes (35): hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF(), hairMp() (+27 more)

### Community 83 - "FBXError"
Cohesion: 0.16
Nodes (9): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, Mapping, controlPoint (+1 more)

### Community 84 - "Ray"
Cohesion: 0.19
Nodes (19): anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery(), intersectAny() (+11 more)

### Community 85 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (10): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+2 more)

### Community 87 - "Double"
Cohesion: 0.07
Nodes (19): Double, Terrain, .cell, Block, City, Flora, Ground, Heavens (+11 more)

### Community 88 - "RendererController"
Cohesion: 0.16
Nodes (5): RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus

### Community 89 - "Float"
Cohesion: 0.14
Nodes (9): Card, Carve, Graft, Grower, LeafRecipe, Level, Recipe, Skeleton (+1 more)

### Community 90 - "CaseIterable"
Cohesion: 0.15
Nodes (11): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+3 more)

### Community 91 - "SurfaceKind"
Cohesion: 0.09
Nodes (15): Maps, ProceduralTextures, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+7 more)

### Community 92 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (3): UpscaleInputs, Upscaler, View

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.13
Nodes (28): cosSubClamped(), inwardPlane(), lightTreeImportance(), lightTreePdf(), lightTreeWeight(), megaLightReach(), megaLightsCullKernel(), megaLightsHashBit() (+20 more)

### Community 95 - ".buildStress"
Cohesion: 0.09
Nodes (15): Ends, Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Hall (+7 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (46): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+38 more)

### Community 99 - "Footprint"
Cohesion: 0.20
Nodes (6): BuildingSpec, BuildingTier, .top, Footprint, .cover, .loops

### Community 100 - "float3"
Cohesion: 0.17
Nodes (25): quatRotate(), physBetween(), physBox(), physBoxGradient(), physBreeze(), physConj(), physDirection(), physDistance() (+17 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (13): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+5 more)

### Community 102 - "SIMD4"
Cohesion: 0.11
Nodes (6): .worldToView, SoftModel, .radius, SIMD4, .xyz, SoftBodyTests

### Community 103 - "uint4"
Cohesion: 0.05
Nodes (41): PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh, pad, shape (+33 more)

### Community 104 - "Building"
Cohesion: 0.18
Nodes (6): Building, .triangleCount, BuildingGenerator, SurfaceMaterial, .uvScale, BuildingTests

### Community 105 - "BuildingStyle"
Cohesion: 0.11
Nodes (17): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+9 more)

### Community 106 - "EnvVariable"
Cohesion: 0.07
Nodes (27): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+19 more)

### Community 107 - "Types.metal"
Cohesion: 0.25
Nodes (6): MaterialTexture, t, RegirParams, RegirReservoir, VSMScene, windOn()

### Community 108 - "PostParams"
Cohesion: 0.17
Nodes (11): Material, albedo, emission, params, textures, PostParams, bloom, finish (+3 more)

### Community 109 - "MeshData"
Cohesion: 0.15
Nodes (12): InstanceBlockRef, records, MeshData, block, cutout, firstIndex, indexCount, lod (+4 more)

### Community 110 - "Species"
Cohesion: 0.10
Nodes (20): Age, mature, sapling, young, Bone, Part, Plant, .height (+12 more)

### Community 111 - ".draw"
Cohesion: 0.12
Nodes (15): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Layouts shared with the shaders: `GPUTypes.swift` ↔ `Shaders/*.metal`, The pass (+7 more)

### Community 112 - "WorldTile"
Cohesion: 0.14
Nodes (5): .time, ChunkRecord, Light, WorldTile, WorldTests

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (33): sdfEval(), sdfJoin(), sdfMarch(), SDFNode, k, kind, material, op (+25 more)

### Community 114 - "Metal"
Cohesion: 0.12
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.08
Nodes (39): physAcross(), physContactKick(), physContactPush(), physHold(), PhysicsBody, angular, info, invInertia (+31 more)

### Community 117 - "BuildingAssembler"
Cohesion: 0.41
Nodes (5): BuildingAssembler, Cell, .center, .width, Opening

### Community 118 - "lumenTraceKernel"
Cohesion: 0.05
Nodes (61): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), LumenParams, grid (+53 more)

### Community 120 - "Benchmark"
Cohesion: 0.06
Nodes (19): M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Render something: `scripts/render.sh`, 6. Math, Modes, Images, Benchmark modes: `Benchmark+Modes.swift`, Benchmark (+11 more)

### Community 121 - "Foliage"
Cohesion: 0.12
Nodes (11): Foliage, Flora, .geometry, .index, .name, Placed, assembly, flat (+3 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 125 - "Map"
Cohesion: 0.07
Nodes (11): Map, TLASUpdate, .descriptor, .descriptor4, BoxData, VoxelGrids, .buffers, .megabytes (+3 more)

### Community 127 - "Primitive"
Cohesion: 0.14
Nodes (13): Node, .transform, Op, intersect, subtract, union, Primitive, box (+5 more)

### Community 128 - "Raster.metal"
Cohesion: 0.19
Nodes (16): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+8 more)

### Community 130 - "Slot"
Cohesion: 0.13
Nodes (14): Slot, accent, blind, dark, floor, frame, glass, interior (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.08
Nodes (30): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+22 more)

### Community 132 - "RasterClusters"
Cohesion: 0.10
Nodes (7): Params, RasterClusters, .drawnByCamera, .stats, .summary, GPUCut, VGCutTests

### Community 133 - "PlantWind"
Cohesion: 0.08
Nodes (40): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+32 more)

### Community 134 - ".write"
Cohesion: 0.18
Nodes (4): BlueNoise, .cacheURL, SplitMix64, CacheFile

### Community 135 - "Chunk"
Cohesion: 0.22
Nodes (6): GPUMaterial, Assembler, Chunk, .triangles, Draft, .triangles

### Community 136 - "LumenCards"
Cohesion: 0.20
Nodes (4): Card, GPULumenCard, LumenCards, .megabytes

### Community 137 - ".planFrame"
Cohesion: 0.08
Nodes (11): MetalKit, GPUPostParams, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets, MegaLightsTargets, PathTracePlan (+3 more)

### Community 139 - "LumenGlobalSDF"
Cohesion: 0.14
Nodes (6): GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, volume, GlobalSDFTests

### Community 141 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (5): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (12): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, rasterVGCutKernel(), rasterVGMeshArgsKernel(), rasterVGRetestKernel(), rvgDraw(), rvgOwners() (+4 more)

### Community 143 - "LightKind"
Cohesion: 0.20
Nodes (10): Light, .isMesh, LightKind, .isSun, mesh, rect, sphere, spot (+2 more)

### Community 145 - "Proving a refactor changed nothing"
Cohesion: 0.21
Nodes (5): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Timings, What could not be run

### Community 146 - "LayerSurface"
Cohesion: 0.11
Nodes (14): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, FrameOutput, LayerSurface, .backingScale, .isVisible (+6 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - "Camera"
Cohesion: 0.18
Nodes (7): Darwin, Camera, .forward, .right, .up, rotate(), scale()

### Community 149 - "Hit"
Cohesion: 0.17
Nodes (10): committedCurve(), Hit, barycentrics, cluster, hit, instance, part, primitive (+2 more)

### Community 150 - "QuartzCore"
Cohesion: 0.18
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - "XCTestCase"
Cohesion: 0.12
Nodes (3): SDFVolume, .hi, SDFTests

### Community 152 - "ComputePass"
Cohesion: 0.09
Nodes (14): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, ComputePass, FrameEncoder, RenderAttachments, Group, PhysicsGPU, .empty, .hasCloth (+6 more)

### Community 153 - "PlantTracing"
Cohesion: 0.11
Nodes (8): Tests, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, RTPart, Wind

### Community 154 - "Crown"
Cohesion: 0.33
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

### Community 155 - "Buffer"
Cohesion: 0.14
Nodes (4): Buffer, mappings, metal3, metal4

### Community 156 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 157 - "CameraTrack"
Cohesion: 0.08
Nodes (18): CameraTrack, .duration, Key, Particles, bubbles, dust, embers, none (+10 more)

### Community 158 - "VirtualTracing"
Cohesion: 0.07
Nodes (13): .instanceDescBuffers, .virtualGeometryChanged, Content, TraceSceneArgs, TraversalStats, .description, .rays, VGView (+5 more)

### Community 159 - "physCollide"
Cohesion: 0.14
Nodes (16): physAdd(), physAddFound(), physAgree(), physArea(), PhysCandidate, n, pa, pb (+8 more)

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.19
Nodes (15): assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true>, octDecode() (+7 more)

### Community 162 - "ImageIO"
Cohesion: 0.19
Nodes (5): AppKit, CoreGraphics, ImageIO, MaterialTextures, UniformTypeIdentifiers

### Community 163 - "RasterVGParams"
Cohesion: 0.11
Nodes (17): RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad (+9 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "SDFShape"
Cohesion: 0.28
Nodes (4): SDFShape, .gpuNodes, .materialCount, .stepScale

### Community 166 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (28): vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere (+20 more)

### Community 170 - "Float"
Cohesion: 0.20
Nodes (4): PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 171 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 172 - "VSM.metal"
Cohesion: 0.18
Nodes (24): shadowVisible(), vsmAllocKernel(), vsmBoxPages(), vsmChunksKernel(), vsmClearVertex(), vsmClip(), vsmClipLocal(), vsmCullKernel() (+16 more)

### Community 174 - "RasterScene"
Cohesion: 0.12
Nodes (10): GPUMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+2 more)

### Community 175 - ".withUnsafeBufferPointer"
Cohesion: 0.20
Nodes (3): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), Hasher, .array

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (14): VSMView, flags, kind, level, light, origin, pages, params (+6 more)

### Community 177 - "Section"
Cohesion: 0.20
Nodes (3): FlippedView, .isFlipped, Section

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (13): VSMScene, bias, camera, flags, forward, lightCount, lights, pool (+5 more)

### Community 180 - ".stages"
Cohesion: 0.18
Nodes (4): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams

### Community 181 - "RendererError"
Cohesion: 0.12
Nodes (4): RendererError, .description, missingFunction, unsupported

### Community 182 - "SceneSettings"
Cohesion: 0.10
Nodes (3): SceneSettings, PlantTracingTests, SceneBuffersTests

### Community 183 - "RasterInstance"
Cohesion: 0.15
Nodes (11): rasterFragment(), RasterInstance, corners, indices, w, x, y, RasterMesh (+3 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "uint"
Cohesion: 0.29
Nodes (10): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+2 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 189 - "SDFBuffers"
Cohesion: 0.25
Nodes (3): BoxData, SDFBuffers, .buffers

### Community 190 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "PrimitiveWork"
Cohesion: 0.22
Nodes (3): PrimitiveRefit, PrimitiveWork, .encoderCount

### Community 194 - "PhysicsJoint"
Cohesion: 0.20
Nodes (10): physAnchorTurnWeight(), physDampJoint(), PhysicsJoint, anchorA, anchorB, axisA, axisB, info (+2 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 196 - "LightTreeNode"
Cohesion: 0.20
Nodes (9): LightTreeNode, axis, hi, link, lo, MegaLightsParams, config, tree (+1 more)

### Community 198 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 200 - "DebugInfo"
Cohesion: 0.25
Nodes (6): DebugInfo, VirtualGeometry, blas, clusters, off, .triangles

### Community 201 - "Metal-only tracer: handoff to the M4 Max (2026-10-06)"
Cohesion: 0.40
Nodes (4): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), Metal-only tracer: handoff to the M4 Max (2026-10-06), Traps, Where things are

### Community 204 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 205 - "PhysPush"
Cohesion: 0.33
Nodes (6): PhysPush, impulse, lambda, ra, rb, speed

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "PhysicsHairVertex"
Cohesion: 0.40
Nodes (5): PhysicsHairVertex, position, previous, rest, velocity

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

## Knowledge Gaps
- **1346 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1341 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1848 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **44 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `.xyz`, `.part`, `.simplify`, `VGStreamer`, `SettingsTable`, `FramePlan`, `GPUProfiler`, `Metal4Frame`, `translate`, `Float`, `LightTable`, `TextureStreamer`, `VirtualGeometry`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `RadianceCascades`, `GPUTypes.swift`, `SectionFile`, `Mesh`, `SettingsTable.swift`, `VSMTargets`, `SceneBuffers`, `LumenScene`, `.meshes`, `FBXReader.swift`, `DebugPanel`, `SceneKind`, `PhysicsWorld`, `String`, `SIMD3`, `FBXFile`, `CityPlan`, `Int32`, `RenderPass`, `VirtualBLAS`, `Pipelines`, `FBXError`, `.icosphere`, `Double`, `RendererController`, `Float`, `CaseIterable`, `SurfaceKind`, `Upscaler`, `.buildStress`, `.length`, `Metal3Pass`, `Footprint`, `SIMD4`, `Building`, `EnvVariable`, `Species`, `.draw`, `WorldTile`, `BuildingAssembler`, `SplitMix64`, `Benchmark`, `Foliage`, `.commit`, `Map`, `CityTests`, `Primitive`, `RagdollTests`, `Slot`, `RasterClusters`, `.write`, `Chunk`, `LumenCards`, `.planFrame`, `RenderPass4`, `LumenGlobalSDF`, `HairTests`, `LightKind`, `LayerSurface`, `Camera`, `XCTestCase`, `ComputePass`, `PlantTracing`, `Buffer`, `Phyllotaxis`, `VirtualTracing`, `SDFShape`, `.encoder`, `Float`, `StressSceneTests`, `RasterScene`, `.stages`, `RendererError`, `SceneSettings`, `FoliageRuntimeTests`, `SDFBuffers`, `PrimitiveWork`, `.int`, `DebugInfo`, `Bool`, `RasterTargets`, `.setBytes`?**
  _High betweenness centrality (0.276) - this node is a cross-community bridge._
- **Why does `Pipelines: `Pipelines.swift`` connect `Pipelines` to `traceKernel`, `restirTemporalKernel`, `restirGIInitialKernel`, `KernelVariantsTests`, `FramePlan`, `Kernel`?**
  _High betweenness centrality (0.134) - this node is a cross-community bridge._
- **Why does `Map` connect `Map` to `GLTFLoader`, `RasterClusters`, `.write`, `VGStreamer`, `KernelVariantsTests`, `TextureStreamer`, `PlantTracing`, `SkinnedCharacter`, `Renderer`, `VirtualTracing`, `TraceScene`, `ImageIO`, `SectionFile`, `SceneBuffers`, `String`, `CityPlan`, `VirtualBLAS`, `Pipelines`, `Double`, `SurfaceKind`, `Upscaler`, `.buildStress`?**
  _High betweenness centrality (0.121) - this node is a cross-community bridge._
- **Are the 33 inferred relationships involving `SIMD3` (e.g. with `.furnish()` and `.init()`) actually correct?**
  _`SIMD3` has 33 INFERRED edges - model-reasoned connections that need verification._
- **Are the 21 inferred relationships involving `Scene` (e.g. with `Scene kinds: `SceneKind` in `Settings.swift`` and `.createSceneResources()`) actually correct?**
  _`Scene` has 21 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `Renderer` (e.g. with `1. The frame loop (`Renderer.draw`)` and `Map`) actually correct?**
  _`Renderer` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1346 weakly-connected nodes found - possible documentation gaps or missing edges._