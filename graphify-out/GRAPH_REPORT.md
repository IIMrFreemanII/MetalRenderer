# Graph Report - MetalRenderer  (2026-10-11)

## Corpus Check
- 297 files · ~1,618,075 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 30 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 3)

## Summary
- 8048 nodes · 24984 edges · 276 communities (225 shown, 51 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3798 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `fb420612`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- Lift
- FramePlan
- common.py
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- String
- rcTraceMergeKernel
- FluidSystem
- HairTests
- Metal4Frame
- translate
- SDFVolume
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- PlantWind
- pathTraceKernel
- LightTable
- MeshBuilder
- RasterClusters
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- Sky.metal
- BuildingAssembler
- restirTemporalKernel
- restirGIInitialKernel
- .stages
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- Foliage
- CaseIterable
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- BVHBuilder
- AppDelegate
- Crowd
- .part
- SIMD3
- SceneKind
- 3D Geometric Test Scene
- .sources
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- float4
- Shaders.metal
- VGBlas
- BuildingCatalog
- Direct Rendering Stress Test 32
- LumenScene
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
- Int
- RendererController
- TextureStreamer
- RasterVGParams
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- clusterWalk
- .buildWorld
- BuildingEditorModel
- regirBuildKernel
- Capabilities
- Tab
- physicsSubstepsKernel
- VGStreamer
- flagOn
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- Crowd.metal
- PhysicsTests
- MuscleTests
- Building
- float3
- ClusterBox
- SoftModel
- float4
- Bool
- BuildingStyle
- EnvVariable
- Flora
- DatasetSpec
- VirtualGeometry
- .writeFrameData
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- NeuralWeights
- Interior
- float4x4
- VirtualBLAS
- LayerSurface
- same.sh
- Key
- baseline.sh
- BuildingPlan
- Map
- export.py
- Raster.metal
- .stages
- AABB
- lumenCardRadiosityKernel
- TraversalStats
- FloorPlan
- PlantEditorTests
- Kind
- PropLibrary
- RoomType
- .buildGallery
- VoxelLOD
- XCTestCase
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- RenderView
- .load
- VSMCounters
- RasterInstance
- FBXError
- QuartzCore
- SettingsStore
- Pipelines
- .galleryFiles
- Curve
- BuildingUse
- Furnisher
- .writeDescriptors
- DebugPanel
- FurnitureItem
- TraceScene
- Intersect.metal
- AppKit
- SDFShape
- related.sh
- SkyParams
- PrimitiveWork
- Hit
- VGParams
- CPU (Swift) practices for MetalRenderer
- .add
- SDFBuffers
- VSM.metal
- Op
- FrameEncoder
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- FleshFigure
- Modes
- MetalGI: the rest of the audit backlog, in seven batches
- VSMParams
- FoliageRuntimeTests
- SceneSettings
- RasterParams
- Role
- Neural.metal
- VSMInstance
- ColliderGrid
- train.py
- PlantTracing
- RasterCounters
- TreePicker
- SIMD4
- .simplify
- PhysicsFleshHeader
- SceneShading
- RagdollTests
- SplitMix
- Benchmark
- .floatCapture
- Tab
- WallGrid
- Terrain
- PhysicsConstraint
- PhysicsGroup
- PhysicsFleshFibre
- PhysicsPair
- PhysicsPoseParams
- SceneBuffersTests
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- FogParams
- traceKernel
- FBXFile
- WorldPlace
- LumenParams
- StressSceneTests
- .init
- DenoisingUpscaler
- RenderThread
- .xyz
- DebugInfo
- HairBSDF
- .commit
- Config
- Clip
- RenderPass4
- PhysicsParams
- Heavens
- Double
- Float
- PipelineCache
- .forestcheck
- Stage
- PlantEditorPanel
- lumen.py
- Buffer
- LoadingOverlay
- WindFrame
- Foliage.Curve
- Material
- Kind
- PostParams
- PhysicsMuscle
- BuildingEditorPanel
- .key
- VoxelGrids
- queryGeometry
- vsmFragment
- PhysicsFleshPin
- SDFBox
- Kind
- PhysicsGrab
- TrainingSceneTests
- RTVoxels
- Where things are
- VGRasterInstance
- .end
- demo-video.sh
- make-dataset.sh

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 480 edges
2. `Scene` - 337 edges
3. `Renderer` - 278 edges
4. `PhysicsWorld` - 275 edges
5. `Kernel` - 163 edges
6. `Benchmark` - 152 edges
7. `SIMD4` - 152 edges
8. `Foliage` - 151 edges
9. `simd` - 147 edges
10. `RenderSettings` - 117 edges

## Surprising Connections (you probably didn't know these)
- `Recipes` --references--> `DemoWalk`  [INFERRED]
  .claude/skills/offscreen/SKILL.md → Sources/MetalRenderer/Benchmark+BuildingsDemo.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `Pass 1: tile cull (`megaLightsCullKernel`)` --references--> `megaLightsCullKernel()`  [INFERRED]
  .claude/memory/plans/megalights.md → Sources/MetalRenderer/Shaders/MegaLights.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift

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

## Communities (276 total, 51 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (37): Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6), GPUEmissiveTriangle, GPUMesh, Assembly, Bone, BorrowedLight, BorrowedMesh, CityLight (+29 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.06
Nodes (46): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+38 more)

### Community 3 - "RenderSettings"
Cohesion: 0.05
Nodes (86): Integration (follow the ReSTIR wiring; refactor-skill rules), Clipboard, File, BuildingStyleDef, Choice, FacadeDef, Finish, InteriorDef (+78 more)

### Community 4 - "Lights.metal"
Cohesion: 0.06
Nodes (69): Denoise, Design, Light influence range (new; nothing in the codebase has a cutoff), Pass 1: tile cull (`megaLightsCullKernel`), Pass 2: sample + trace (`megaLightsSampleKernel`), clipSegment(), ggxFromDirection(), groupElement() (+61 more)

### Community 5 - "Lift"
Cohesion: 0.10
Nodes (16): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Switch, Lift (+8 more)

### Community 6 - "FramePlan"
Cohesion: 0.12
Nodes (23): B. Remaining per-frame CPU, Backlog: the rest of the audit, D. Structure / duplication, 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, GPUPostParams, CompositeInputs (+15 more)

### Community 7 - "common.py"
Cohesion: 0.12
Nodes (13): aces(), array_path(), clip_dirs(), display(), frames(), held(), load(), matches() (+5 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (82): fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf(), fluidCellsClearKernel(), fluidCellSortKernel() (+74 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.07
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 10 - "PlantEditorModel"
Cohesion: 0.04
Nodes (38): Where things are, .hasBoughs, .isTree, Clip, graft, habitat, leaves, level (+30 more)

### Community 11 - "String"
Cohesion: 0.04
Nodes (20): Settings: `SettingsTable.swift`, Things that are not structures yet, Where new code belongs, StyleDraw, CatalogRegistry, Section, Frame, SkyMode (+12 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.13
Nodes (14): Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), rcClearAmbientKernel(), rcEvalSH(), RCParams, grids, interval, layout, RCProbeBatch (+6 more)

### Community 13 - "FluidSystem"
Cohesion: 0.18
Nodes (11): .surfaceCapacity, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims, .domain, .mass (+3 more)

### Community 16 - "translate"
Cohesion: 0.19
Nodes (10): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Stand (+2 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (3): SDFVolume, .hi, SDFTests

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.16
Nodes (15): Pass 3: resolve (`megaLightsResolveKernel`, full res), 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 8. Pipelines and resources, GPU (Metal / MSL) practices for MetalRenderer (+7 more)

### Community 19 - "Fog.metal"
Cohesion: 0.16
Nodes (24): fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel(), fogMedium() (+16 more)

### Community 20 - "PlantWind"
Cohesion: 0.08
Nodes (40): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+32 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (60): makeRay(), pathTraceKernel(), PathTraceParams, bounds, config, samples, ptEval(), PTFog (+52 more)

### Community 22 - "LightTable"
Cohesion: 0.53
Nodes (4): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount

### Community 23 - "MeshBuilder"
Cohesion: 0.09
Nodes (15): .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, Hall, Loop (+7 more)

### Community 24 - "RasterClusters"
Cohesion: 0.10
Nodes (8): Params, RasterClusters, .drawnByCamera, .stats, .summary, VGView, GPUCut, VGCutTests

### Community 25 - "LightSampling.metal"
Cohesion: 0.12
Nodes (32): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+24 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.13
Nodes (10): Clip, .duration, .loopKeys, Level, .triangleCount, Part, SkinnedCharacter, .bindPoses (+2 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (16): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+8 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (141): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+133 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (7): Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (47): done, LoadOptions, PreparedScene, Renderer, .accumulating, .activeDirectMode, .activeGIMode, .cameraClusters (+39 more)

### Community 31 - "Sky.metal"
Cohesion: 0.14
Nodes (26): atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity(), cloudHeight(), cloudMarch() (+18 more)

### Community 32 - "BuildingAssembler"
Cohesion: 0.16
Nodes (9): BuildingAssembler, Cell, .center, .width, Opening, Ends, upper, .outerThickness (+1 more)

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (17): shadowOrigin(), emptyReservoir(), packReservoir(), Reservoir, element, M, uv, visible (+9 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (31): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+23 more)

### Community 35 - ".stages"
Cohesion: 0.18
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "GPUTypes.swift"
Cohesion: 0.10
Nodes (30): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUInstanceData, GPUJoint, GPUJointMatrix, GPUMegaLightsParams, GPUMuscle (+22 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.10
Nodes (11): CryptoKit, GeneratedCache, Hasher, SectionFile, Stored, .array, .count, .data (+3 more)

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (41): physCell(), physColourPairs(), physColoursAround(), physDirection(), physDistance2(), physFlat(), physHash(), physicsClearKernel() (+33 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - "Foliage"
Cohesion: 0.05
Nodes (32): Age, mature, sapling, young, Bone, Card, Foliage, Grower (+24 more)

### Community 42 - "CaseIterable"
Cohesion: 0.03
Nodes (99): Scope, all, floor, .name, Role, bush, groundCover, tree (+91 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (16): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Kind, sphere, spot (+8 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.08
Nodes (17): .empty, .instanceScratch, .namedBlocks, .namedInstanceBlocks, .namedPrimitives, RendererError, .description, missingFunction (+9 more)

### Community 45 - "View"
Cohesion: 0.08
Nodes (53): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+45 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (8): Blue Hemisphere, Green Vertical Plane, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism, Yellow Cube

### Community 47 - "BVHBuilder"
Cohesion: 0.12
Nodes (9): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.13
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - ".part"
Cohesion: 0.18
Nodes (8): CharacterImporter, Mapping, controlPoint, polygonVertex, Skeleton, .bindPositions, .bindRotations, SourceClip

### Community 51 - "SIMD3"
Cohesion: 0.08
Nodes (13): Int32, GPUFluidParams, GPUFluidParticle, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, LocalIds (+5 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (41): SceneKind, area, buildings, .cameraFromScene, city, cityNight, cornell, crowd (+33 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - ".sources"
Cohesion: 0.19
Nodes (3): Maps, ProceduralTextures, ProceduralTextureTests

### Community 55 - "Color Bleeding from Walls to Objects"
Cohesion: 0.40
Nodes (6): Color Bleeding from Walls to Objects, Direct and Indirect Illumination Effects, Geometric Primitives (Cylinder, Cube, Sphere, Rectangular Blocks), Global Illumination Reference Scene, Primary Light Source, Varied Material Surfaces and Reflectivity

### Community 56 - "3D Graphics Stress Test Scene"
Cohesion: 0.33
Nodes (5): Albedo Reference Image 1.5x, Color Palette Distribution, Geometric Shapes, 3D Spatial Layout, 3D Graphics Stress Test Scene

### Community 57 - "Direct Lighting Reference Render"
Cohesion: 0.40
Nodes (5): Geometric Complexity, Lighting Quality and Shadows, Material Properties and Colors, Direct Lighting Reference Render, Rendering Stress Test

### Community 59 - "MuscleAtlas"
Cohesion: 0.07
Nodes (32): .programme, .parent, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas (+24 more)

### Community 60 - "float4"
Cohesion: 0.18
Nodes (10): FogVolume, albedoEdge, centerShape, extentDensity, params, Light, axis, color (+2 more)

### Community 61 - "Shaders.metal"
Cohesion: 0.03
Nodes (77): glassKernel(), glassReflection(), reflectionHitRadiance(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent(), cloudShadow() (+69 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (19): VGBlas, attrs, pad0, pad1, pad2, triangles, tris, VGClusterView (+11 more)

### Community 63 - "BuildingCatalog"
Cohesion: 0.10
Nodes (13): interior, .currentOverride, .currentRef, BuildingCatalog, .fingerprint, .launch, BuildingStore, .encoder (+5 more)

### Community 64 - "Direct Rendering Stress Test 32"
Cohesion: 0.60
Nodes (4): 3D Geometry Rendering, Direct Rendering Technique, Complex Lighting Environment, Direct Rendering Stress Test 32

### Community 65 - "LumenScene"
Cohesion: 0.16
Nodes (7): GPULumenMeshSDF, GPULumenSDFInstance, LumenScene, .isBaking, .isCancelled, .megabytes, Source

### Community 67 - "Geometric Objects (Box, Cube, Sphere)"
Cohesion: 1.00
Nodes (3): Geometric Objects (Box, Cube, Sphere), Point Light Source, Shadow Casting on Surfaces

### Community 72 - "VirtualTracing"
Cohesion: 0.09
Nodes (9): .instanceAS, .virtualGeometryChanged, Content, TraceSceneArgs, VirtualTracing, .extraInstances, .pool, .summary (+1 more)

### Community 73 - "CityPlan"
Cohesion: 0.06
Nodes (31): To do on the M4 Max, .entry, .well, Core, .all, .stairPlan, Mode, backCore (+23 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.06
Nodes (19): GPUHairGroup, GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsParticle, Cloth, PhysicsJoint, PhysicsJointKind (+11 more)

### Community 76 - "Int"
Cohesion: 0.04
Nodes (12): Batch 5: per-frame CPU, Metal3RenderPass, PrimitiveRefit, RenderPass, Card, GPULumenCard, LumenCards, .megabytes (+4 more)

### Community 77 - "RendererController"
Cohesion: 0.11
Nodes (11): .buildingPlan, .buildingStats, .cameraPosition, .walker, .plantStats, RendererController, .debugActive, .debugInfo (+3 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.08
Nodes (13): Entry, Level, SparseMapping, TextureStreamer, .details, .levelProgress, .placement, .residentLevels (+5 more)

### Community 79 - "RasterVGParams"
Cohesion: 0.11
Nodes (17): RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad (+9 more)

### Community 80 - "KernelVariants"
Cohesion: 0.18
Nodes (6): Pipelines: `Pipelines.swift`, finish, .function, KernelVariants, .count, Key

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.11
Nodes (12): To do on the M4 Max, Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled (+4 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (38): lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel() (+30 more)

### Community 84 - "clusterWalk"
Cohesion: 0.43
Nodes (6): 4. Divergence and memory access patterns, clusterWalk(), octDecode(), rtSafeInverse(), rtSlab(), rtTriangle()

### Community 85 - ".buildWorld"
Cohesion: 0.08
Nodes (20): SurfaceMaterial, .uvScale, SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel (+12 more)

### Community 86 - "BuildingEditorModel"
Cohesion: 0.07
Nodes (14): BuildingEditorHost, BuildingEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key, .savedDef (+6 more)

### Community 87 - "regirBuildKernel"
Cohesion: 0.12
Nodes (17): regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup(), RegirParams (+9 more)

### Community 88 - "Capabilities"
Cohesion: 0.21
Nodes (5): Capabilities: `Capabilities.swift`, Capabilities, .summary, CapabilitiesTests, .none

### Community 89 - "Tab"
Cohesion: 0.29
Nodes (7): Tab, ages, boughs, habitat, leaves, look, stems

### Community 90 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 91 - "VGStreamer"
Cohesion: 0.13
Nodes (6): BuddyAllocator, Group, VGStreamer, .groupCount, .isSettled, .residentMB

### Community 92 - "flagOn"
Cohesion: 0.13
Nodes (20): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), finiteSample() (+12 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (3): UpscaleInputs, Upscaler, View

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (37): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+29 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (14): Metal3Pass, .declarationScope, FluidWorld, LiquidKind, blood, honey, .look, .name (+6 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (45): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+37 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (41): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail, flat (+33 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (30): physAcross(), physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient(), PhysCandidate (+22 more)

### Community 101 - "ClusterBox"
Cohesion: 0.14
Nodes (13): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+5 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (5): NearCache, SoftModel, .near, .radius, SoftBodyTests

### Community 103 - "float4"
Cohesion: 0.04
Nodes (57): physBetween(), physBreeze(), PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh (+49 more)

### Community 104 - "Bool"
Cohesion: 0.10
Nodes (19): PlanDoor, PlanRoom, .area, StoreyPlanner, Rect, .center, .size, LotRef (+11 more)

### Community 105 - "BuildingStyle"
Cohesion: 0.09
Nodes (20): Balustrade, bars, glass, solid, BuildingStyle, .isOffice, PlanShape, courtyard (+12 more)

### Community 106 - "EnvVariable"
Cohesion: 0.04
Nodes (52): on, .reservoirCount, Control, checkbox, custom, popup, slider, Custom (+44 more)

### Community 107 - "Flora"
Cohesion: 0.06
Nodes (21): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+13 more)

### Community 108 - "DatasetSpec"
Cohesion: 0.16
Nodes (10): CameraDrift, ClipStyle, held, moving, paused, DatasetClip, DatasetFrame, .cameraPose (+2 more)

### Community 109 - "VirtualGeometry"
Cohesion: 0.11
Nodes (12): Build, Params, VGPipelines, VirtualGeometry, .clusterCount, .groupCount, .meshCount, .pool (+4 more)

### Community 110 - ".writeFrameData"
Cohesion: 0.10
Nodes (5): GPUFogParams, .reflectionPassFlags, GPUFogVolume, .instanceDescBuffers, .materialBuffers

### Community 111 - "CurveEditor"
Cohesion: 0.12
Nodes (11): CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey, EnvironmentValues, .editorDrag (+3 more)

### Community 112 - "WorldTile"
Cohesion: 0.10
Nodes (11): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+3 more)

### Community 113 - "SDFNode"
Cohesion: 0.07
Nodes (44): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+36 more)

### Community 114 - "Metal"
Cohesion: 0.10
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.06
Nodes (33): physContactKick(), physContactPush(), PhysicsBody, angular, info, invInertia, position, prevPosition (+25 more)

### Community 117 - "NeuralWeights"
Cohesion: 0.05
Nodes (23): tensors, GPUNeuralParams, NeuralError, format, memory, NeuralInputs, NeuralPipelines, NeuralUpscaler (+15 more)

### Community 118 - "Interior"
Cohesion: 0.13
Nodes (14): Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder, LiftShaft, Maker (+6 more)

### Community 119 - "float4x4"
Cohesion: 0.06
Nodes (23): Batch 6: load time, Darwin, Prop, GLTFModel, .bounds, .triangleCount, Light, Camera (+15 more)

### Community 120 - "VirtualBLAS"
Cohesion: 0.16
Nodes (11): Where things are, Built, CutInput, Entry, VirtualBLAS, .instanceCount, .isBusy, .meshCount (+3 more)

### Community 121 - "LayerSurface"
Cohesion: 0.14
Nodes (10): FrameOutput, Headless, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title (+2 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.11
Nodes (13): Keys, hi, lo, Key, crown, linear, points, taper (+5 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.21
Nodes (6): DemoWalk, Point, CameraTrack, .duration, Key, BuildingPlan

### Community 126 - "Map"
Cohesion: 0.10
Nodes (12): Map, BlueNoise, .cacheURL, SplitMix64, CacheFile, MaterialTextures, FluidSurface, dims (+4 more)

### Community 127 - "export.py"
Cohesion: 0.13
Nodes (11): row(), golden(), main(), write_nnw(), chw(), main(), run_clip(), guides() (+3 more)

### Community 128 - "Raster.metal"
Cohesion: 0.17
Nodes (18): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+10 more)

### Community 129 - ".stages"
Cohesion: 0.17
Nodes (4): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams

### Community 130 - "AABB"
Cohesion: 0.11
Nodes (14): AABB, .area, .centroid, .isEmpty, Baked, bricks, heights, Heightfield (+6 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.05
Nodes (54): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+46 more)

### Community 132 - "TraversalStats"
Cohesion: 0.25
Nodes (5): 9. Shader helpers: use them, don't copy, TraversalStats, .description, .line, .rays

### Community 133 - "FloorPlan"
Cohesion: 0.20
Nodes (3): FloorPlan, .height, BuildingPlanTests

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "PropLibrary"
Cohesion: 0.44
Nodes (3): Entry, File, PropLibrary

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (34): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+26 more)

### Community 138 - ".buildGallery"
Cohesion: 0.09
Nodes (4): LoadStep, SplitMix64, MeshSDFBuilderTests, SplitMix

### Community 139 - "VoxelLOD"
Cohesion: 0.17
Nodes (4): .megabytes, Entry, VoxelLOD, .megabytes

### Community 140 - "XCTestCase"
Cohesion: 0.11
Nodes (8): Cluster, Group, .isRoot, VGCluster, VirtualGeometryBuilder, VirtualMesh, CacheTests, VGStreamerTests

### Community 141 - "FluidSurface.metal"
Cohesion: 0.37
Nodes (12): fluidCorner(), fluidSurfaceBlurKernel(), fluidSurfaceCell(), fluidSurfaceClearKernel(), fluidSurfaceCoords(), fluidSurfaceCountKernel(), fluidSurfaceEdges(), fluidSurfaceNode() (+4 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.21
Nodes (12): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, rasterVGCutKernel(), rasterVGMeshArgsKernel(), rasterVGRetestKernel(), rvgDraw(), rvgOwners() (+4 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (6): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial()

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (3): InputHandler, RenderView, .acceptsFirstResponder

### Community 146 - ".load"
Cohesion: 0.08
Nodes (12): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, LoadError, unreadable, GLTFError, .description (+4 more)

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - "RasterInstance"
Cohesion: 0.20
Nodes (9): RasterInstance, corners, indices, w, x, y, RasterMesh, hi (+1 more)

### Community 149 - "FBXError"
Cohesion: 0.17
Nodes (8): FBXError, .description, unsupported, BlobReader, BlobWriter, CharacterLibrary, .directory, concurrently()

### Community 150 - "QuartzCore"
Cohesion: 0.11
Nodes (5): Combine, MetalFX, MetalKit, QuartzCore, Array

### Community 151 - "SettingsStore"
Cohesion: 0.14
Nodes (7): The pass, The pass after a feature, The report and the commit message, What stays fixed, What to look for, base, SettingsStore

### Community 152 - "Pipelines"
Cohesion: 0.09
Nodes (19): ComputePass, Step, FluidGPU, .summary, Steps, System, Group, PhysicsGPU (+11 more)

### Community 154 - "Curve"
Cohesion: 0.13
Nodes (14): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+6 more)

### Community 155 - "BuildingUse"
Cohesion: 0.14
Nodes (13): Tool, door, look, merge, split, type, wall, BuildingUse (+5 more)

### Community 156 - "Furnisher"
Cohesion: 0.18
Nodes (10): Furnisher, Light, Prefer, any, away, corner, middle, window (+2 more)

### Community 157 - ".writeDescriptors"
Cohesion: 0.14
Nodes (4): Tests, RTPart, Wind, PlantTracingTests

### Community 158 - "DebugPanel"
Cohesion: 0.10
Nodes (7): F. Housekeeping, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, cpu

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "Intersect.metal"
Cohesion: 0.15
Nodes (36): anyHit(), assumeCurves(), assumeCurveShape(), boxCandidate(), candidate(), candidateIndex(), candidatePart(), card() (+28 more)

### Community 162 - "AppKit"
Cohesion: 0.16
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "SDFShape"
Cohesion: 0.06
Nodes (29): GPURasterMesh, Kind, arrays, block, clusters, skip, virtual, RasterScene (+21 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 166 - "PrimitiveWork"
Cohesion: 0.20
Nodes (5): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, PrimitiveWork, .encoderCount

### Community 167 - "Hit"
Cohesion: 0.17
Nodes (10): committedCurve(), Hit, barycentrics, cluster, hit, instance, part, primitive (+2 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (28): vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere (+20 more)

### Community 169 - "CPU (Swift) practices for MetalRenderer"
Cohesion: 0.09
Nodes (18): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+10 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (3): Hash, .value, PlantGoldenTests

### Community 171 - "SDFBuffers"
Cohesion: 0.24
Nodes (3): BoxData, SDFBuffers, .buffers

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (14): shadowVisible(), vsmBoxPages(), vsmClip(), vsmClipLocal(), vsmCullKernel(), vsmDebugKernel(), vsmEntry(), vsmFootprint() (+6 more)

### Community 173 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

### Community 174 - "FrameEncoder"
Cohesion: 0.06
Nodes (11): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameEncoder, Metal3Frame, RenderAttachments, TLASUpdate, .descriptor, GPUProfiler, GPURasterParams (+3 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.23
Nodes (8): FloorPlanView, .body, .help, .picked, .status, .storeys, .toolbar, Mapping

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (14): VSMView, flags, kind, level, light, origin, pages, params (+6 more)

### Community 177 - "PlantParam"
Cohesion: 0.13
Nodes (5): .body, PlantMutate, PlantParam, .isInteger, PlantParams

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (13): VSMScene, bias, camera, flags, forward, lightCount, lights, pool (+5 more)

### Community 180 - "uint"
Cohesion: 0.32
Nodes (10): vsmAllocKernel(), vsmChunksKernel(), vsmClearVertex(), vsmFreeKernel(), vsmPageClip(), vsmResetKernel(), vsmSettleKernel(), vsmTag() (+2 more)

### Community 181 - "FleshFigure"
Cohesion: 0.10
Nodes (13): GPUSoftVertex, .cells, Flesh, FleshOptions, MuscleSpec, Side, back, front (+5 more)

### Community 182 - "Modes"
Cohesion: 0.15
Nodes (13): Batch 2: shader duplication, Batch 4: small GPU items, Batch 7: housekeeping, C. GPU, Step 1: safety (A-items), no image change except A3, Benchmarks and eval, Context, MegaLights-style direct lighting (new `DirectLightMode.megalights`) (+5 more)

### Community 183 - "MetalGI: the rest of the audit backlog, in seven batches"
Cohesion: 0.08
Nodes (19): Batch 3: launch time, Context, Context, Earlier plan (done on 2026-10-03): safety fixes + market CPU wins, MetalGI: the rest of the audit backlog, in seven batches, Not in this plan, Rules for every batch, Step 2: cheap per-frame and load wins (+11 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "SceneSettings"
Cohesion: 0.08
Nodes (11): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), SceneSettings (+3 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 190 - "Neural.metal"
Cohesion: 0.15
Nodes (15): neuralConvKernel(), neuralCubic(), neuralCubicFar(), neuralCubicNear(), neuralFinishKernel(), neuralKernelFinishKernel(), neuralLogLight(), NeuralParams (+7 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.16
Nodes (7): ColliderGrid, Input, Moving, Walker, .eyePosition, .height, WalkerTests

### Community 193 - "train.py"
Cohesion: 0.10
Nodes (7): augment(), Sequences, display(), loss_fn(), step(), masked_l1(), run_sequence()

### Community 194 - "PlantTracing"
Cohesion: 0.15
Nodes (5): PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 197 - "SIMD4"
Cohesion: 0.09
Nodes (15): GPUPhysicsShape, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box, capsule (+7 more)

### Community 198 - ".simplify"
Cohesion: 0.29
Nodes (3): MeshSimplifier, Quadric, .edges

### Community 199 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 200 - "SceneShading"
Cohesion: 0.12
Nodes (14): MaterialTexture, t, SceneShading, cloudShadow, emissive, feedback, materials, minLod (+6 more)

### Community 203 - "Benchmark"
Cohesion: 0.07
Nodes (14): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+6 more)

### Community 204 - ".floatCapture"
Cohesion: 0.16
Nodes (3): DatasetCapture, inputs, reference

### Community 205 - "Tab"
Cohesion: 0.25
Nodes (8): Tab, facade, floors, furnish, look, massing, rooms, site

### Community 206 - "WallGrid"
Cohesion: 0.25
Nodes (8): WallGrid, .alongX, .e, .hi, .line, .lines, .lo, .middles

### Community 208 - "PhysicsConstraint"
Cohesion: 0.40
Nodes (5): PhysicsConstraint, a, b, compliance, rest

### Community 209 - "PhysicsGroup"
Cohesion: 0.40
Nodes (5): PhysicsGroup, count, first, last, pad

### Community 210 - "PhysicsFleshFibre"
Cohesion: 0.16
Nodes (11): PhysicsFleshFibre, compliance, g, muscle, pad0, pad1, PhysicsHairVertex, position (+3 more)

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

### Community 218 - "FogParams"
Cohesion: 0.25
Nodes (8): FogParams, albedo, counts, grid, medium, noise, volumes, wind

### Community 219 - "traceKernel"
Cohesion: 0.05
Nodes (66): Batch 1: shader file split, 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic() (+58 more)

### Community 220 - "FBXFile"
Cohesion: 0.12
Nodes (12): Compression, Children, Connection, Contents, FBXArrayElement, invalid, FBXFile, .topLevel (+4 more)

### Community 223 - "LumenParams"
Cohesion: 0.25
Nodes (6): LumenParams, grid, options, screen, sdf, tuning

### Community 225 - ".init"
Cohesion: 0.07
Nodes (9): E. Load time, Launch time, Atmosphere, SkyImage, Launch, FogNoise, resourceCreation, unsupported (+1 more)

### Community 226 - "DenoisingUpscaler"
Cohesion: 0.18
Nodes (3): conv(), DenoisingUpscaler, warp()

### Community 228 - ".xyz"
Cohesion: 0.13
Nodes (4): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .bodies

### Community 229 - "DebugInfo"
Cohesion: 0.25
Nodes (7): Step 0: baseline and a CPU meter, DebugInfo, VirtualGeometry, blas, clusters, off, .triangles

### Community 232 - "Config"
Cohesion: 0.08
Nodes (3): 6. Math, Benchmark modes: `Benchmark+Modes.swift`, Config

### Community 233 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "Double"
Cohesion: 0.11
Nodes (13): Double, World, .anchorTile, .start, Block, City, Flora, Ground (+5 more)

### Community 238 - "Float"
Cohesion: 0.19
Nodes (4): Event, callLift, flashlight, lights

### Community 240 - ".forestcheck"
Cohesion: 0.25
Nodes (5): M1 Max numbers (whole frame ms, `METALRENDERER_BENCH_SPLIT=0`), M4 Max results (2026-10-07, after main was merged in at `0d1cc14`), Metal-only tracer: handoff to the M4 Max (2026-10-06), To do on the M4 Max, in order (1, 2, 3 and 6 done on 2026-10-07: see above), Traps

### Community 241 - "Stage"
Cohesion: 0.13
Nodes (14): Particles, bubbles, dust, embers, none, runes, Stage, crypt (+6 more)

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (3): PlantEditorPanel, .isVisible, .wasVisible

### Community 245 - "Buffer"
Cohesion: 0.14
Nodes (4): Buffer, mappings, metal3, metal4

### Community 246 - "LoadingOverlay"
Cohesion: 0.10
Nodes (10): LoadingOverlay, .isEnabled, Model, heading, item, Row, State, failed (+2 more)

### Community 247 - "WindFrame"
Cohesion: 0.43
Nodes (4): PlantKey, WindFrame, .plantKey, .poseKey

### Community 249 - "Material"
Cohesion: 0.33
Nodes (5): Material, albedo, emission, params, textures

### Community 250 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 251 - "PostParams"
Cohesion: 0.33
Nodes (6): PostParams, bloom, finish, frame, lens, size

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "BuildingEditorPanel"
Cohesion: 0.20
Nodes (3): BuildingEditorPanel, .isVisible, .wasVisible

### Community 255 - "VoxelGrids"
Cohesion: 0.18
Nodes (8): FoliageVoxels, Grid, Piece, Plant, BoxData, VoxelGrids, .buffers, .megabytes

### Community 256 - "queryGeometry"
Cohesion: 0.50
Nodes (3): queryGeometry(), queryParams(), voxelParams()

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 259 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (5): Kind, furniture, glass, solid, stair

### Community 262 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 264 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 265 - "Where things are"
Cohesion: 0.12
Nodes (5): Where things are, BuildingMutate, BuildingParams, BuildingEditorTests, Host

### Community 267 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

## Knowledge Gaps
- **1790 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1785 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2454 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **51 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `Lift`, `FramePlan`, `PlantEditorModel`, `String`, `FluidSystem`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `LightTable`, `MeshBuilder`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `BuildingAssembler`, `.stages`, `GPUTypes.swift`, `GeneratedCache`, `Foliage`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `View`, `BVHBuilder`, `Crowd`, `.part`, `SIMD3`, `SceneKind`, `.sources`, `MuscleAtlas`, `BuildingCatalog`, `LumenScene`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `VGStreamer`, `Upscaler`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Bool`, `EnvVariable`, `Flora`, `DatasetSpec`, `VirtualGeometry`, `.writeFrameData`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `float4x4`, `VirtualBLAS`, `LayerSurface`, `BuildingPlan`, `Map`, `.stages`, `AABB`, `TraversalStats`, `FloorPlan`, `PropLibrary`, `RoomType`, `.buildGallery`, `VoxelLOD`, `XCTestCase`, `FBXError`, `QuartzCore`, `Pipelines`, `.galleryFiles`, `Curve`, `Furnisher`, `.writeDescriptors`, `DebugPanel`, `FurnitureItem`, `SDFShape`, `PrimitiveWork`, `SDFBuffers`, `FrameEncoder`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `Modes`, `FoliageRuntimeTests`, `SceneSettings`, `Role`, `.setBytes`, `ColliderGrid`, `PlantTracing`, `SIMD4`, `.simplify`, `RagdollTests`, `Benchmark`, `.floatCapture`, `Terrain`, `SceneBuffersTests`, `FBXFile`, `WorldPlace`, `StressSceneTests`, `.init`, `.xyz`, `DebugInfo`, `.commit`, `Config`, `RenderPass4`, `Double`, `Float`, `PipelineCache`, `Buffer`, `LoadingOverlay`, `WindFrame`, `.key`, `.encoder`, `TrainingSceneTests`, `Where things are`, `.init`?**
  _High betweenness centrality (0.280) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `RenderSettings`, `Lift`, `FramePlan`, `PlantEditorModel`, `translate`, `RasterClusters`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `GeneratedCache`, `Foliage`, `CaseIterable`, `SceneBuffers`, `View`, `BVHBuilder`, `.part`, `SIMD3`, `SceneKind`, `MuscleAtlas`, `BuildingCatalog`, `VirtualTracing`, `Int`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `Capabilities`, `Tab`, `VGStreamer`, `Upscaler`, `Metal3Pass`, `Bool`, `BuildingStyle`, `EnvVariable`, `Flora`, `DatasetSpec`, `VirtualGeometry`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `float4x4`, `VirtualBLAS`, `LayerSurface`, `Key`, `BuildingPlan`, `TraversalStats`, `FloorPlan`, `PlantEditorTests`, `Kind`, `PropLibrary`, `RoomType`, `.buildGallery`, `XCTestCase`, `.load`, `FBXError`, `SettingsStore`, `Pipelines`, `.galleryFiles`, `Curve`, `BuildingUse`, `DebugPanel`, `PrimitiveWork`, `.add`, `Op`, `FrameEncoder`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `Modes`, `SceneSettings`, `Benchmark`, `Tab`, `SceneBuffersTests`, `FBXFile`, `.init`, `DebugInfo`, `.commit`, `Config`, `Clip`, `Double`, `Buffer`, `LoadingOverlay`, `Kind`, `VoxelGrids`, `.encoder`, `Where things are`?**
  _High betweenness centrality (0.109) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `RenderSettings`, `Lift`, `FramePlan`, `PlantEditorModel`, `String`, `HairTests`, `Metal4Frame`, `translate`, `MeshBuilder`, `RasterClusters`, `SettingsPanel`, `Renderer`, `BuildingAssembler`, `Foliage`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `View`, `BVHBuilder`, `AppDelegate`, `Crowd`, `.part`, `SIMD3`, `SceneKind`, `BuildingCatalog`, `LumenScene`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `Int`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `VGStreamer`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `BuildingStyle`, `EnvVariable`, `Flora`, `DatasetSpec`, `VirtualGeometry`, `.writeFrameData`, `WorldTile`, `NeuralWeights`, `Interior`, `float4x4`, `VirtualBLAS`, `LayerSurface`, `BuildingPlan`, `AABB`, `FloorPlan`, `RoomType`, `.buildGallery`, `VoxelLOD`, `XCTestCase`, `RenderView`, `.load`, `FBXError`, `Pipelines`, `Curve`, `Furnisher`, `.writeDescriptors`, `DebugPanel`, `SDFShape`, `FrameEncoder`, `PlantParam`, `FleshFigure`, `FoliageRuntimeTests`, `SceneSettings`, `ColliderGrid`, `PlantTracing`, `TreePicker`, `SIMD4`, `.simplify`, `RagdollTests`, `Benchmark`, `WallGrid`, `SceneBuffersTests`, `.capture`, `.init`, `RenderThread`, `.xyz`, `DebugInfo`, `.commit`, `Config`, `Heavens`, `Double`, `Float`, `PlantEditorPanel`, `LoadingOverlay`, `WindFrame`, `BuildingEditorPanel`, `.key`, `VoxelGrids`, `.encoder`?**
  _High betweenness centrality (0.105) - this node is a cross-community bridge._
- **Are the 51 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 51 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Batch 6: load time` and `Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1790 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.0395118230358505 - nodes in this community are weakly interconnected._