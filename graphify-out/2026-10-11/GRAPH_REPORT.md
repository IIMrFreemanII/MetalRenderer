# Graph Report - MetalRenderer  (2026-10-10)

## Corpus Check
- 297 files · ~1,615,944 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 30 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 3)

## Summary
- 8035 nodes · 24961 edges · 276 communities (222 shown, 54 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3796 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `018ce306`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- Codable
- Lights.metal
- Lift
- PlantCatalog
- common.py
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- CGFloat
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
- float4x4
- VirtualMesh
- LightSampling.metal
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- RasterScene
- BuildingAssembler
- restirTemporalKernel
- restirGIInitialKernel
- .stages
- GPUTypes.swift
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- .write
- CaseIterable
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- BVHBuilder
- AppDelegate
- Crowd
- VirtualGeometry
- LumenGlobalSDF
- SceneKind
- 3D Geometric Test Scene
- PhysicsWorld
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- Types.metal
- reflectionKernel
- SDFBox
- InstanceData
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
- Int32
- simd
- RenderPass
- RendererController
- TextureStreamer
- Double
- KernelVariants
- ab.sh
- LoadActivity
- instanceRecord
- Intersect.metal
- .buildWorld
- BuildingEditorModel
- regirBuildKernel
- Capabilities
- Foliage
- physicsSubstepsKernel
- BuildingStyle
- flagOn
- Upscaler
- megaLightsSampleKernel
- Metal3Pass
- Crowd.metal
- PhysicsTests
- MuscleTests
- Building
- float3
- RTVoxels
- SoftModel
- float4
- Bool
- String
- RenderSettings
- FoliageTextures
- LotOverride
- EnvVariable
- .planFrame
- CurveEditor
- WorldTile
- SDFNode
- Metal
- PhysicsBody
- render.sh
- NeuralWeights
- Interior
- AABB
- VirtualBLAS
- Flora
- same.sh
- Key
- baseline.sh
- BuildingPlan
- SurfaceKind
- train.py
- Raster.metal
- Int
- MeshSDF
- lumenCardRadiosityKernel
- .writeFrameData
- PlantWind
- PlantEditorTests
- Kind
- Stored
- RoomType
- .build
- Map
- .build
- FluidSurface.metal
- RasterClusters.metal
- liquidKernel
- audit-backlog-2026-10.md
- RenderView
- .load
- VSMCounters
- .pieces
- CharacterRig
- QuartzCore
- MeshBuilder
- Pipelines
- CodingKeys
- Curve
- Post.metal
- Furnisher
- FloorPlan
- DebugPanel
- FurnitureItem
- TraceScene
- uint
- AppKit
- SDFShape
- related.sh
- Role
- .load
- Habitat
- VGParams
- MetalGI: the rest of the audit backlog, in seven batches
- .add
- Assembler
- VSM.metal
- .span
- Metal3Frame
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- .addFleshCharacter
- Config
- Slot
- VSMParams
- FoliageRuntimeTests
- Where things are
- RasterParams
- Role
- GPUFogParams
- Neural.metal
- VSMInstance
- ColliderGrid
- dataset.py
- PlantTracing
- RasterCounters
- TLASUpdate
- Float
- .simplify
- PhysicsFleshHeader
- SceneShading
- .step
- .addHair
- Benchmark
- .encodeOutput
- .clusterize
- Op
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
- Foliage.Phyllotaxis
- traceKernel
- FBXFile
- RasterSceneTests
- WorldPlace
- LumenParams
- StressSceneTests
- SkyImage
- .forward
- RenderThread
- SIMD3
- run_sequence
- HairBSDF
- .commit
- SceneSettings
- Clip
- RenderPass4
- PhysicsParams
- Heavens
- World
- Camera
- Key
- SplitMix64
- Stage
- PlantEditorPanel
- numpy
- .building
- Buffer
- LoadingOverlay
- View
- VoxelBox
- KernelVariantsTests
- Kind
- PhysicsMuscle
- BuildingEditorPanel
- .problems
- FoliageVoxels
- Sides
- vsmFragment
- PhysicsFleshPin
- PlantWindParams
- Kind
- PrimitiveRefit
- PhysicsGrab
- XCTestCase
- .curve
- Kind
- fetchHitVertices
- GPUProfiler
- demo-video.sh
- make-dataset.sh

## God Nodes (most connected - your core abstractions)
1. `SIMD3` - 480 edges
2. `Scene` - 337 edges
3. `Renderer` - 278 edges
4. `PhysicsWorld` - 275 edges
5. `Kernel` - 163 edges
6. `SIMD4` - 152 edges
7. `Benchmark` - 151 edges
8. `Foliage` - 151 edges
9. `simd` - 147 edges
10. `RenderSettings` - 117 edges

## Surprising Connections (you probably didn't know these)
- `Recipes` --references--> `DemoWalk`  [INFERRED]
  .claude/skills/offscreen/SKILL.md → Sources/MetalRenderer/Benchmark+BuildingsDemo.swift
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `Step 0: baseline and a CPU meter` --references--> `DebugInfo`  [INFERRED]
  .claude/memory/plans/audit-backlog.md → Sources/MetalRenderer/DebugPanel.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal

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

## Communities (276 total, 54 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (46): Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6), GPUEmissiveTriangle, GPUMesh, meshLights, Assembly, Bone, BorrowedLight, BorrowedMesh (+38 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.13
Nodes (25): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+17 more)

### Community 3 - "Codable"
Cohesion: 0.06
Nodes (56): Clipboard, BuildingStyleDef, Choice, FacadeDef, Finish, InteriorDef, MassingDef, MaterialDef (+48 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (63): Pass 2: sample + trace (`megaLightsSampleKernel`), clipSegment(), ggxFromDirection(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget() (+55 more)

### Community 5 - "Lift"
Cohesion: 0.10
Nodes (16): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Switch, Lift (+8 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.09
Nodes (12): PlantCatalog, .count, .covers, File, Foliage.SpeciesDef, .fingerprint, .launch, .placementFingerprint (+4 more)

### Community 7 - "common.py"
Cohesion: 0.11
Nodes (16): aces(), array_path(), clip_dirs(), display(), frames(), load(), matches(), paused() (+8 more)

### Community 8 - "Fluid.metal"
Cohesion: 0.06
Nodes (82): fluidApplyKernel(), fluidBeginKernel(), fluidCell(), fluidCellCountKernel(), fluidCellIndex(), fluidCellOf(), fluidCellsClearKernel(), fluidCellSortKernel() (+74 more)

### Community 9 - "evalcommon.py"
Cohesion: 0.07
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 10 - "PlantEditorModel"
Cohesion: 0.06
Nodes (23): Combine, Array, Clip, graft, habitat, leaves, level, look (+15 more)

### Community 11 - "CGFloat"
Cohesion: 0.15
Nodes (10): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface (+2 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (19): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, rcClearAmbientKernel(), rcEvalSH() (+11 more)

### Community 13 - "FramePlan"
Cohesion: 0.18
Nodes (12): B. Remaining per-frame CPU, 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize (+4 more)

### Community 16 - "translate"
Cohesion: 0.15
Nodes (12): Scene kinds: `SceneKind` in `Settings.swift`, Darwin, scale(), translate(), FogVolume, .gpu, LightPose, Kit (+4 more)

### Community 17 - "SDFVolume"
Cohesion: 0.12
Nodes (3): SDFVolume, .hi, SDFTests

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.11
Nodes (22): Denoise, Design, Light influence range (new; nothing in the codebase has a cutoff), Pass 1: tile cull (`megaLightsCullKernel`), Pass 3: resolve (`megaLightsResolveKernel`, full res), 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes (+14 more)

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

### Community 23 - "float4x4"
Cohesion: 0.12
Nodes (12): GPUMaterial, rotate(), float4x4, Hall, Loop, .length, Props, Zone (+4 more)

### Community 24 - "VirtualMesh"
Cohesion: 0.09
Nodes (10): Where things are, Params, RasterClusters, .drawnByCamera, .stats, .summary, VGView, VirtualMesh (+2 more)

### Community 25 - "LightSampling.metal"
Cohesion: 0.09
Nodes (41): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), giLightIllum(), lastFramePixel(), LightCandidate, element, uv (+33 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.10
Nodes (15): GPUJoint, .parent, GPUSkinVertex, CharacterLibrary, .directory, Clip, .duration, .loopKeys (+7 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.20
Nodes (16): distance, lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel() (+8 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (141): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+133 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.10
Nodes (8): Settings: `SettingsTable.swift`, Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 30 - "Renderer"
Cohesion: 0.03
Nodes (49): Integration (follow the ReSTIR wiring; refactor-skill rules), To do on the M4 Max, Launch, done, PreparedScene, Renderer, .accumulating, .activeDirectMode (+41 more)

### Community 31 - "RasterScene"
Cohesion: 0.14
Nodes (9): Kind, arrays, block, clusters, skip, virtual, RasterScene, .megabytes (+1 more)

### Community 32 - "BuildingAssembler"
Cohesion: 0.18
Nodes (7): BuildingAssembler, Cell, .center, .width, Opening, upper, .outerThickness

### Community 33 - "restirTemporalKernel"
Cohesion: 0.12
Nodes (17): emptyReservoir(), packReservoir(), Reservoir, element, M, uv, visible, W (+9 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (31): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+23 more)

### Community 35 - ".stages"
Cohesion: 0.18
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "GPUTypes.swift"
Cohesion: 0.09
Nodes (31): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUHairGroup, GPUHairParams, GPUHairStrand, GPUInstanceData, GPUJointMatrix (+23 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.13
Nodes (5): CryptoKit, GeneratedCache, SectionFile, Writer, Section

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (41): physCell(), physColourPairs(), physColoursAround(), physDirection(), physDistance2(), physFlat(), physHash(), physicsClearKernel() (+33 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.15
Nodes (9): LeafShape, blade, kite, needle, Mesh, .leafTriangles, .triangles, MeshSize (+1 more)

### Community 42 - "CaseIterable"
Cohesion: 0.03
Nodes (85): Tab, ages, boughs, habitat, leaves, look, stems, DirectLightMode (+77 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (17): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, VSMSettings, Kind, sphere (+9 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (19): .empty, RTPart, LoadOptions, RendererError, .description, missingFunction, InstanceBlock, .held (+11 more)

### Community 45 - "View"
Cohesion: 0.07
Nodes (53): .body, BuildingLookTab, .body, CaseChoiceRow, .body, ColorListRow, .body, FacadeTab (+45 more)

### Community 46 - "3D Rendered Scene with Geometric Primitives"
Cohesion: 0.28
Nodes (8): Blue Hemisphere, Green Vertical Plane, Ambient Light Source, Pink Rectangular Prism, Red Vertical Plane, 3D Rendered Scene with Geometric Primitives, White Rectangular Prism, Yellow Cube

### Community 47 - "BVHBuilder"
Cohesion: 0.12
Nodes (9): BinScratch, BVHBuilder, BVHNode, Node, Part, built, .count, split (+1 more)

### Community 49 - "Crowd"
Cohesion: 0.14
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - "VirtualGeometry"
Cohesion: 0.08
Nodes (13): Batch 5: per-frame CPU, Build, Params, VGPipelines, VirtualGeometry, .clusterCount, .groupCount, .meshCount (+5 more)

### Community 51 - "LumenGlobalSDF"
Cohesion: 0.08
Nodes (10): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes (+2 more)

### Community 52 - "SceneKind"
Cohesion: 0.05
Nodes (40): SceneKind, area, buildings, .cameraFromScene, city, cityNight, cornell, crowd (+32 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "PhysicsWorld"
Cohesion: 0.09
Nodes (12): GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, PhysicsWorld, .buckets, .cellSize, .kinematicRows, .params (+4 more)

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
Cohesion: 0.21
Nodes (5): Mark, Muscle, MuscleAtlas, Place, Shape

### Community 60 - "Types.metal"
Cohesion: 0.06
Nodes (38): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+30 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.03
Nodes (80): glassKernel(), glassReflection(), reflectionHitRadiance(), reflectionKernel(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent() (+72 more)

### Community 62 - "SDFBox"
Cohesion: 0.10
Nodes (20): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag (+12 more)

### Community 63 - "InstanceData"
Cohesion: 0.09
Nodes (21): InstanceBlockRef, records, InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1 (+13 more)

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
Cohesion: 0.11
Nodes (5): .virtualGeometryChanged, VirtualTracing, .extraInstances, .pool, .summary

### Community 73 - "CityPlan"
Cohesion: 0.05
Nodes (46): To do on the M4 Max, Core, .all, .stairPlan, Mode, backCore, frontCore, none (+38 more)

### Community 74 - "Int32"
Cohesion: 0.10
Nodes (14): Int32, .surfaceCapacity, GPUFluidParams, GPUFluidParticle, GPUFluidSurface, FluidSystem, .capacity, .cell (+6 more)

### Community 77 - "RendererController"
Cohesion: 0.08
Nodes (18): .buildingPlan, .buildingStats, .cameraPosition, .walker, DebugInfo, VirtualGeometry, blas, clusters (+10 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.07
Nodes (14): Entry, Level, SparseMapping, TextureStreamer, .details, .levelProgress, .placement, .residentLevels (+6 more)

### Community 79 - "Double"
Cohesion: 0.21
Nodes (5): Double, City, Flora, Highway, Placement

### Community 80 - "KernelVariants"
Cohesion: 0.19
Nodes (5): Pipelines: `Pipelines.swift`, finish, .function, KernelVariants, .count

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.09
Nodes (12): Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, LoadStep, .isCancelled (+4 more)

### Community 83 - "instanceRecord"
Cohesion: 0.08
Nodes (39): lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel() (+31 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.13
Nodes (27): assumeCurveShape(), boxCandidate(), candidateIndex(), candidatePart(), card(), clusterWalk(), commitCurve(), commitCurveCandidate() (+19 more)

### Community 85 - ".buildWorld"
Cohesion: 0.15
Nodes (8): SurfaceMaterial, .uvScale, Prop, WalkArea, BuildingKit, TextureSource, .identity, .rawPixels

### Community 86 - "BuildingEditorModel"
Cohesion: 0.05
Nodes (20): Where things are, BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def, .inWorkshop, .isBuiltIn (+12 more)

### Community 87 - "regirBuildKernel"
Cohesion: 0.11
Nodes (17): regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup(), RegirParams (+9 more)

### Community 88 - "Capabilities"
Cohesion: 0.20
Nodes (5): Capabilities: `Capabilities.swift`, Capabilities, .summary, CapabilitiesTests, .none

### Community 89 - "Foliage"
Cohesion: 0.08
Nodes (28): Age, mature, sapling, young, Bone, Card, Carve, Foliage (+20 more)

### Community 90 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 91 - "BuildingStyle"
Cohesion: 0.09
Nodes (20): Balustrade, bars, glass, solid, BuildingStyle, .isOffice, PlanShape, courtyard (+12 more)

### Community 92 - "flagOn"
Cohesion: 0.20
Nodes (14): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), finiteSample() (+6 more)

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (37): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+29 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.09
Nodes (14): Metal3Pass, .declarationScope, FluidWorld, LiquidKind, blood, honey, .look, .name (+6 more)

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (45): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+37 more)

### Community 98 - "MuscleTests"
Cohesion: 0.11
Nodes (5): centre, BoxData, SDFBuffers, .buffers, MuscleTests

### Community 99 - "Building"
Cohesion: 0.08
Nodes (23): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Detail, flat (+15 more)

### Community 100 - "float3"
Cohesion: 0.11
Nodes (30): physAcross(), physAdd(), physAddFound(), physAgree(), physArea(), physBox(), physBoxGradient(), PhysCandidate (+22 more)

### Community 101 - "RTVoxels"
Cohesion: 0.10
Nodes (18): BVHNode, hi0, hi1, lo0, lo1, ClusterBox, index, mask (+10 more)

### Community 102 - "SoftModel"
Cohesion: 0.10
Nodes (7): GPUPhysicsParticle, .particleCellSize, NearCache, SoftModel, .near, .radius, SoftBodyTests

### Community 103 - "float4"
Cohesion: 0.04
Nodes (57): physBetween(), physBreeze(), PhysicsCloth, grid, previous, PhysicsHairGroup, counts, mesh (+49 more)

### Community 104 - "Bool"
Cohesion: 0.09
Nodes (20): PlanDoor, PlanRoom, .area, StoreyPlanner, .programme, Rect, .center, .size (+12 more)

### Community 105 - "String"
Cohesion: 0.04
Nodes (44): Tab, facade, floors, furnish, look, massing, rooms, site (+36 more)

### Community 106 - "RenderSettings"
Cohesion: 0.06
Nodes (27): on, RenderSettings, SettingsEnv, Control, checkbox, custom, popup, slider (+19 more)

### Community 107 - "FoliageTextures"
Cohesion: 0.15
Nodes (10): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+2 more)

### Community 108 - "LotOverride"
Cohesion: 0.09
Nodes (17): interior, .fingerprint, .launch, BuildingStore, .encoder, .folder, Draft, File (+9 more)

### Community 109 - "EnvVariable"
Cohesion: 0.07
Nodes (29): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+21 more)

### Community 110 - ".planFrame"
Cohesion: 0.08
Nodes (14): MetalKit, FogNoise, GPUPostParams, DenoiseSignal, DenoiseTargets, FogTargets, LiquidTargets, MegaLightsTargets (+6 more)

### Community 111 - "CurveEditor"
Cohesion: 0.10
Nodes (13): CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey, EnvironmentValues, .editorDrag (+5 more)

### Community 112 - "WorldTile"
Cohesion: 0.14
Nodes (8): .time, Chunk, .triangles, ChunkRecord, Light, WorldTile, .triangles, WorldTests

### Community 113 - "SDFNode"
Cohesion: 0.08
Nodes (33): sdfEval(), sdfJoin(), sdfMarch(), SDFNode, k, kind, material, op (+25 more)

### Community 114 - "Metal"
Cohesion: 0.09
Nodes (3): Metal, MetalRenderer, XCTest

### Community 115 - "PhysicsBody"
Cohesion: 0.06
Nodes (33): physContactKick(), physContactPush(), PhysicsBody, angular, info, invInertia, position, prevPosition (+25 more)

### Community 117 - "NeuralWeights"
Cohesion: 0.06
Nodes (19): tensors, GPUNeuralParams, NeuralError, format, memory, NeuralInputs, NeuralPipelines, NeuralUpscaler (+11 more)

### Community 118 - "Interior"
Cohesion: 0.12
Nodes (15): Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder, LiftShaft, Maker (+7 more)

### Community 119 - "AABB"
Cohesion: 0.07
Nodes (10): Batch 6: load time, AABB, .area, .centroid, .isEmpty, GLTFModel, .bounds, .triangleCount (+2 more)

### Community 120 - "VirtualBLAS"
Cohesion: 0.16
Nodes (11): Built, CutInput, Entry, VirtualBLAS, .instanceCount, .isBusy, .meshCount, .sourceTriangles (+3 more)

### Community 121 - "Flora"
Cohesion: 0.13
Nodes (10): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+2 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (11): Keys, hi, lo, Foliage.Curve, Key, crown, linear, points (+3 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.21
Nodes (6): DemoWalk, Point, CameraTrack, .duration, Key, BuildingPlan

### Community 126 - "SurfaceKind"
Cohesion: 0.05
Nodes (20): BlueNoise, .cacheURL, SplitMix64, CacheFile, Maps, ProceduralTextures, SurfaceKind, asphalt (+12 more)

### Community 127 - "train.py"
Cohesion: 0.13
Nodes (9): golden(), main(), write_nnw(), conv(), DenoisingUpscaler, guides(), prepare(), to_linear() (+1 more)

### Community 128 - "Raster.metal"
Cohesion: 0.12
Nodes (27): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+19 more)

### Community 129 - "Int"
Cohesion: 0.07
Nodes (14): Ends, Card, GPULumenCard, LumenCards, .megabytes, Faces, Int, .envText (+6 more)

### Community 130 - "MeshSDF"
Cohesion: 0.14
Nodes (10): Baked, bricks, Heightfield, .hi, MeshSDF, .bytes, .hi, .storedBricks (+2 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.11
Nodes (22): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+14 more)

### Community 132 - ".writeFrameData"
Cohesion: 0.10
Nodes (8): .instanceAS, .instanceDescBuffers, .materialBuffers, Content, TraceSceneArgs, TraversalStats, .description, .line

### Community 133 - "PlantWind"
Cohesion: 0.10
Nodes (34): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+26 more)

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "Stored"
Cohesion: 0.15
Nodes (9): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), Entry, File, PropLibrary, Hasher, Stored, .array, .count (+1 more)

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (34): CityPlan.Rect, .area, RoomType, backroom, bath, bedroom, corridor, dining (+26 more)

### Community 139 - "Map"
Cohesion: 0.07
Nodes (14): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures, .megabytes, BoxData (+6 more)

### Community 140 - ".build"
Cohesion: 0.16
Nodes (5): Cluster, Group, .isRoot, VGCluster, VirtualGeometryBuilder

### Community 141 - "FluidSurface.metal"
Cohesion: 0.21
Nodes (18): fluidCorner(), FluidSurface, dims, field, lo, mesh, triangles, fluidSurfaceBlurKernel() (+10 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.08
Nodes (33): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, RasterMeshVertex, rasterVGCutKernel(), rasterVGMeshArgsKernel(), RasterVGParams, capacity (+25 more)

### Community 143 - "liquidKernel"
Cohesion: 0.15
Nodes (6): Where things are, liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial()

### Community 144 - "audit-backlog-2026-10.md"
Cohesion: 0.09
Nodes (10): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, 1. Make the dataset, 2. Train, 3. Use it in the app, Our own denoising upscaler (+2 more)

### Community 145 - "RenderView"
Cohesion: 0.08
Nodes (3): InputHandler, RenderView, .acceptsFirstResponder

### Community 146 - ".load"
Cohesion: 0.20
Nodes (3): Failure, ShaderSource, ShaderSourceTests

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - ".pieces"
Cohesion: 0.39
Nodes (3): Piece, SkeletonAtlas, Solid

### Community 149 - "CharacterRig"
Cohesion: 0.23
Nodes (5): BodyMarks, BodySurface, .bounds, trunk, CharacterRig

### Community 150 - "QuartzCore"
Cohesion: 0.12
Nodes (3): MetalFX, QuartzCore, Headless

### Community 151 - "MeshBuilder"
Cohesion: 0.17
Nodes (6): .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount

### Community 152 - "Pipelines"
Cohesion: 0.08
Nodes (19): ComputePass, Step, FluidGPU, .summary, Steps, System, Group, PhysicsGPU (+11 more)

### Community 153 - "CodingKeys"
Cohesion: 0.16
Nodes (12): Arch, CodingKeys, arch, factor, guides, head, hidden, inputs (+4 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (14): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+6 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (11): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+3 more)

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (11): Furnisher, FurnishPalette, Light, Prefer, any, away, corner, middle (+3 more)

### Community 157 - "FloorPlan"
Cohesion: 0.24
Nodes (3): FloorPlan, .height, BuildingPlanTests

### Community 158 - "DebugPanel"
Cohesion: 0.08
Nodes (7): DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, Section, cpu

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "uint"
Cohesion: 0.15
Nodes (26): anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery(), Hit (+18 more)

### Community 162 - "AppKit"
Cohesion: 0.13
Nodes (4): AppKit, CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "SDFShape"
Cohesion: 0.13
Nodes (18): Node, .transform, Op, intersect, subtract, union, Primitive, box (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "Role"
Cohesion: 0.16
Nodes (13): Role, chest, foot, forearm, hand, head, neck, pelvis (+5 more)

### Community 166 - ".load"
Cohesion: 0.23
Nodes (7): GLTFError, .description, invalid, unsupported, Image, Material, TextureRef

### Community 167 - "Habitat"
Cohesion: 0.36
Nodes (4): Habitat, Ramp, TreePicker, .isEmpty

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (29): isFar(), vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset (+21 more)

### Community 169 - "MetalGI: the rest of the audit backlog, in seven batches"
Cohesion: 0.05
Nodes (32): Batch 7: housekeeping, Context, Context, Earlier plan (done on 2026-10-03): safety fixes + market CPU wins, MetalGI: the rest of the audit backlog, in seven batches, Not in this plan, Rules for every batch, Step 0: baseline and a CPU meter (+24 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (3): Hash, .value, PlantGoldenTests

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (14): shadowVisible(), vsmBoxPages(), vsmClip(), vsmClipLocal(), vsmCullKernel(), vsmDebugKernel(), vsmEntry(), vsmFootprint() (+6 more)

### Community 175 - "FloorPlanView"
Cohesion: 0.23
Nodes (8): FloorPlanView, .body, .help, .picked, .status, .storeys, .toolbar, Mapping

### Community 176 - "VSMView"
Cohesion: 0.13
Nodes (14): VSMView, flags, kind, level, light, origin, pages, params (+6 more)

### Community 177 - "PlantParam"
Cohesion: 0.21
Nodes (4): .body, PlantParam, .isInteger, PlantParams

### Community 178 - "VSMClusterArgs"
Cohesion: 0.13
Nodes (15): VSMClusterArgs, changed, clusters, groupPage, groups, instanceCount, lastUsed, pool (+7 more)

### Community 179 - "VSMScene"
Cohesion: 0.14
Nodes (13): VSMScene, bias, camera, flags, forward, lightCount, lights, pool (+5 more)

### Community 180 - "uint"
Cohesion: 0.32
Nodes (10): vsmAllocKernel(), vsmChunksKernel(), vsmClearVertex(), vsmFreeKernel(), vsmPageClip(), vsmResetKernel(), vsmSettleKernel(), vsmTag() (+2 more)

### Community 181 - ".addFleshCharacter"
Cohesion: 0.09
Nodes (12): GPUSoftVertex, Cloth, Flesh, MuscleSpec, Side, back, front, out (+4 more)

### Community 182 - "Config"
Cohesion: 0.05
Nodes (30): Batch 1: shader file split, Batch 2: shader duplication, Batch 3: launch time, Batch 4: small GPU items, C. GPU, Benchmarks and eval, Context, MegaLights-style direct lighting (new `DirectLightMode.megalights`) (+22 more)

### Community 183 - "Slot"
Cohesion: 0.11
Nodes (18): Slot, accent, blind, dark, floor, frame, glass, .isFill (+10 more)

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "Where things are"
Cohesion: 0.20
Nodes (5): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, PlantWorkshopTests

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 189 - "GPUFogParams"
Cohesion: 0.22
Nodes (8): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, GPUFogParams, .reflectionPassFlags, GPUFogVolume

### Community 190 - "Neural.metal"
Cohesion: 0.16
Nodes (15): neuralConvKernel(), neuralCubic(), neuralCubicFar(), neuralCubicNear(), neuralFinishKernel(), neuralKernelFinishKernel(), neuralLogLight(), NeuralParams (+7 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.25
Nodes (7): .cells, ColliderGrid, Input, Moving, Walker, .eyePosition, .height

### Community 194 - "PlantTracing"
Cohesion: 0.07
Nodes (12): Tests, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, Wind, PlantKey (+4 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 196 - "TLASUpdate"
Cohesion: 0.22
Nodes (3): TLASUpdate, .descriptor, .descriptor4

### Community 197 - "Float"
Cohesion: 0.16
Nodes (5): GPUPhysicsShape, PhysicsJoint, PhysicsJointKind, ball, hinge

### Community 198 - ".simplify"
Cohesion: 0.29
Nodes (3): MeshSimplifier, Quadric, .edges

### Community 199 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 200 - "SceneShading"
Cohesion: 0.07
Nodes (27): MaterialTexture, t, SceneShading, cloudShadow, emissive, feedback, materials, minLod (+19 more)

### Community 203 - "Benchmark"
Cohesion: 0.06
Nodes (15): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+7 more)

### Community 204 - ".encodeOutput"
Cohesion: 0.10
Nodes (6): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameEncoder, RenderAttachments, UpscaleInputs, .instanceDataBuffers, RenderSurface

### Community 206 - "Op"
Cohesion: 0.22
Nodes (9): Op, addDoor, flipDoor, merge, moveDoor, moveWall, removeDoor, setType (+1 more)

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

### Community 218 - "Foliage.Phyllotaxis"
Cohesion: 0.28
Nodes (3): Foliage.Phyllotaxis, FoliageTextures.Kind, .all

### Community 219 - "traceKernel"
Cohesion: 0.06
Nodes (56): D. Structure / duplication, 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic() (+48 more)

### Community 220 - "FBXFile"
Cohesion: 0.07
Nodes (26): Compression, Children, Connection, Contents, FBXArrayElement, FBXError, .description, invalid (+18 more)

### Community 223 - "LumenParams"
Cohesion: 0.25
Nodes (6): LumenParams, grid, options, screen, sdf, tuning

### Community 225 - "SkyImage"
Cohesion: 0.13
Nodes (8): Backlog: the rest of the audit, E. Load time, F. Housekeeping, Atmosphere, LoadError, unreadable, SkyImage, volume

### Community 228 - "SIMD3"
Cohesion: 0.07
Nodes (19): GPUHairVertex, GPURasterMesh, PhysicsCandidate, .middle, PhysicsManifold, PhysicsMath, PhysicsShapeKind, box (+11 more)

### Community 229 - "run_sequence"
Cohesion: 0.25
Nodes (5): display(), loss_fn(), step(), masked_l1(), run_sequence()

### Community 232 - "SceneSettings"
Cohesion: 0.08
Nodes (8): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), Not checked anywhere, fog, SceneSettings, BuildingWorkshopTests, ForestTests, ShowcaseTests

### Community 233 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Heavens"
Cohesion: 0.24
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "World"
Cohesion: 0.13
Nodes (8): World, .anchorTile, .start, Block, Ground, Road, Roadbeds, .treeCell

### Community 238 - "Camera"
Cohesion: 0.10
Nodes (15): CameraDrift, DatasetClip, DatasetFrame, .cameraPose, DatasetSpec, .clipList, Event, callLift (+7 more)

### Community 239 - "Key"
Cohesion: 0.39
Nodes (3): Key, PipelineCache, .count

### Community 241 - "Stage"
Cohesion: 0.25
Nodes (8): Stage, crypt, forge, neon, sanctum, studio, underwater, workshop

### Community 242 - "PlantEditorPanel"
Cohesion: 0.21
Nodes (3): PlantEditorPanel, .isVisible, .wasVisible

### Community 245 - "Buffer"
Cohesion: 0.14
Nodes (4): Buffer, mappings, metal3, metal4

### Community 246 - "LoadingOverlay"
Cohesion: 0.10
Nodes (10): LoadingOverlay, .isEnabled, Model, heading, item, Row, State, failed (+2 more)

### Community 247 - "View"
Cohesion: 0.29
Nodes (7): View, cutaway, dollhouse, full, plant, skeleton, .title

### Community 248 - "VoxelBox"
Cohesion: 0.29
Nodes (7): VoxelBox, cells, grid, level, pad0, pad1, pad2

### Community 250 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "BuildingEditorPanel"
Cohesion: 0.22
Nodes (3): BuildingEditorPanel, .isVisible, .wasVisible

### Community 255 - "FoliageVoxels"
Cohesion: 0.47
Nodes (4): FoliageVoxels, Grid, Piece, Plant

### Community 256 - "Sides"
Cohesion: 0.33
Nodes (6): Sides, backToBack, corner, free, row, .title

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 259 - "PlantWindParams"
Cohesion: 0.33
Nodes (6): PlantWindParams, count, pad, stride, time, wind

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (5): Kind, furniture, glass, solid, stair

### Community 261 - "PrimitiveRefit"
Cohesion: 0.18
Nodes (6): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max, PrimitiveRefit, PrimitiveWork, .encoderCount

### Community 262 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 263 - "XCTestCase"
Cohesion: 0.13
Nodes (5): bulbRoom, GLTFLoaderTests, PipelineCacheTests, TrainingSceneTests, VGStreamerTests

### Community 264 - ".curve"
Cohesion: 0.40
Nodes (4): Axis, along, front, up

### Community 266 - "Kind"
Cohesion: 0.50
Nodes (4): Kind, directional, point, spot

### Community 273 - "GPUProfiler"
Cohesion: 0.09
Nodes (4): Frame, GPUProfiler, Optional, .passProfilingSupported

## Knowledge Gaps
- **1785 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1780 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2447 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **54 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `Codable`, `Lift`, `PlantCatalog`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `SDFVolume`, `GPU (Metal / MSL) practices for MetalRenderer`, `LightTable`, `float4x4`, `VirtualMesh`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `RasterScene`, `BuildingAssembler`, `.stages`, `GeneratedCache`, `.write`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `View`, `BVHBuilder`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `PhysicsWorld`, `MuscleAtlas`, `LumenScene`, `VirtualTracing`, `CityPlan`, `Int32`, `RenderPass`, `RendererController`, `TextureStreamer`, `Double`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `Foliage`, `Upscaler`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Bool`, `String`, `RenderSettings`, `FoliageTextures`, `LotOverride`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `AABB`, `VirtualBLAS`, `Flora`, `BuildingPlan`, `SurfaceKind`, `MeshSDF`, `.writeFrameData`, `Stored`, `RoomType`, `.build`, `Map`, `.build`, `audit-backlog-2026-10.md`, `.pieces`, `CharacterRig`, `MeshBuilder`, `Pipelines`, `CodingKeys`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `FurnitureItem`, `SDFShape`, `.load`, `Assembler`, `.span`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `.addFleshCharacter`, `Config`, `Slot`, `FoliageRuntimeTests`, `Role`, `GPUFogParams`, `ColliderGrid`, `PlantTracing`, `TLASUpdate`, `Float`, `.simplify`, `.step`, `.addHair`, `Benchmark`, `.encodeOutput`, `.clusterize`, `Terrain`, `SceneBuffersTests`, `FBXFile`, `RasterSceneTests`, `WorldPlace`, `StressSceneTests`, `SkyImage`, `SIMD3`, `.commit`, `SceneSettings`, `RenderPass4`, `World`, `Camera`, `Key`, `SplitMix64`, `.building`, `Buffer`, `LoadingOverlay`, `View`, `.problems`, `FoliageVoxels`, `Sides`, `PrimitiveRefit`, `XCTestCase`, `.curve`, `.dispatchThreadgroups`, `GPUProfiler`?**
  _High betweenness centrality (0.279) - this node is a cross-community bridge._
- **Why does `Bool` connect `Bool` to `Scene`, `GLTFLoader`, `Codable`, `Lift`, `PlantCatalog`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `HairTests`, `Metal4Frame`, `translate`, `float4x4`, `VirtualMesh`, `SkinnedCharacter`, `SettingsPanel`, `Renderer`, `RasterScene`, `BuildingAssembler`, `.write`, `CaseIterable`, `VSMTargets`, `SceneBuffers`, `View`, `BVHBuilder`, `AppDelegate`, `Crowd`, `VirtualGeometry`, `LumenGlobalSDF`, `SceneKind`, `PhysicsWorld`, `LumenScene`, `VirtualTracing`, `CityPlan`, `Int32`, `RendererController`, `TextureStreamer`, `Double`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `Foliage`, `BuildingStyle`, `Upscaler`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `String`, `RenderSettings`, `FoliageTextures`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `AABB`, `VirtualBLAS`, `Flora`, `BuildingPlan`, `SurfaceKind`, `Int`, `MeshSDF`, `RoomType`, `Map`, `.build`, `audit-backlog-2026-10.md`, `RenderView`, `.load`, `MeshBuilder`, `Pipelines`, `Curve`, `Furnisher`, `FloorPlan`, `DebugPanel`, `SDFShape`, `Habitat`, `Assembler`, `Metal3Frame`, `PlantParam`, `.addFleshCharacter`, `Config`, `Slot`, `FoliageRuntimeTests`, `Where things are`, `GPUFogParams`, `ColliderGrid`, `PlantTracing`, `TLASUpdate`, `Float`, `.simplify`, `.step`, `.addHair`, `Benchmark`, `.encodeOutput`, `.clusterize`, `SceneBuffersTests`, `FBXFile`, `SkyImage`, `RenderThread`, `SIMD3`, `.commit`, `SceneSettings`, `Heavens`, `World`, `Camera`, `Key`, `PlantEditorPanel`, `LoadingOverlay`, `BuildingEditorPanel`, `.problems`, `FoliageVoxels`, `XCTestCase`, `GPUProfiler`?**
  _High betweenness centrality (0.142) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `Codable`, `Lift`, `PlantCatalog`, `PlantEditorModel`, `CGFloat`, `FramePlan`, `Metal4Frame`, `translate`, `VirtualMesh`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `GeneratedCache`, `.write`, `CaseIterable`, `SceneBuffers`, `View`, `BVHBuilder`, `VirtualGeometry`, `SceneKind`, `MuscleAtlas`, `VirtualTracing`, `CityPlan`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `Capabilities`, `Foliage`, `BuildingStyle`, `Upscaler`, `Metal3Pass`, `Bool`, `RenderSettings`, `FoliageTextures`, `LotOverride`, `EnvVariable`, `.planFrame`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `AABB`, `VirtualBLAS`, `Flora`, `Key`, `BuildingPlan`, `SurfaceKind`, `Int`, `.writeFrameData`, `PlantEditorTests`, `Kind`, `Stored`, `RoomType`, `Map`, `.build`, `.load`, `.pieces`, `CharacterRig`, `Pipelines`, `CodingKeys`, `Curve`, `FloorPlan`, `DebugPanel`, `.load`, `MetalGI: the rest of the audit backlog, in seven batches`, `.add`, `.span`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `.addFleshCharacter`, `Config`, `Where things are`, `TLASUpdate`, `Benchmark`, `.encodeOutput`, `Op`, `SceneBuffersTests`, `FBXFile`, `SkyImage`, `SIMD3`, `.commit`, `SceneSettings`, `Clip`, `World`, `Camera`, `Buffer`, `LoadingOverlay`, `View`, `KernelVariantsTests`, `Kind`, `.problems`, `FoliageVoxels`, `Sides`, `PrimitiveRefit`, `.worldView`, `GPUProfiler`?**
  _High betweenness centrality (0.113) - this node is a cross-community bridge._
- **Are the 51 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 51 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Batch 6: load time` and `Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1785 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.03850333799099519 - nodes in this community are weakly interconnected._