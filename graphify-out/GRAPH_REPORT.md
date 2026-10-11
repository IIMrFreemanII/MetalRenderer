# Graph Report - MetalRenderer  (2026-10-11)

## Corpus Check
- 297 files · ~1,617,111 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 30 file(s) not represented in the graph (top: .fbx 12, .glb 11, (none) 3)

## Summary
- 8042 nodes · 24973 edges · 277 communities (229 shown, 48 thin omitted)
- Extraction: 85% EXTRACTED · 15% INFERRED · 0% AMBIGUOUS · INFERRED: 3797 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `018ce306`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- Scene
- MetalGI Real-Time Ray Tracer
- GLTFLoader
- RenderSettings
- Lights.metal
- Lift
- PlantCatalog
- common.py
- Fluid.metal
- evalcommon.py
- PlantEditorModel
- SettingsTableTests
- rcTraceMergeKernel
- FluidSystem
- HairTests
- Metal4Frame
- translate
- SDFTests
- GPU (Metal / MSL) practices for MetalRenderer
- Fog.metal
- pcgHash
- pathTraceKernel
- LightTable
- float4x4
- Int
- lightType
- SkinnedCharacter
- lumenTraceKernel
- Kernel
- SettingsPanel
- Renderer
- .init
- BuildingAssembler
- restirTemporalKernel
- restirGIInitialKernel
- .stages
- SIMD4
- 3D Scene Composition
- GeneratedCache
- Physics.metal
- Uniforms
- .write
- String
- VSMTargets
- SceneBuffers
- View
- 3D Rendered Scene with Geometric Primitives
- BVHBuilder
- AppDelegate
- Crowd
- .part
- SIMD3
- SceneSettings
- 3D Geometric Test Scene
- ProceduralTextures
- Color Bleeding from Walls to Objects
- 3D Graphics Stress Test Scene
- Direct Lighting Reference Render
- Geometric Primitives Rendering Test
- MuscleAtlas
- Types.metal
- reflectionKernel
- VGBlas
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
- PhysicsWorld
- simd
- RenderPass
- RendererController
- TextureStreamer
- RasterVGParams
- KernelVariants
- ab.sh
- LoadActivity
- LumenSDF.metal
- Intersect.metal
- .buildWorld
- BuildingEditorModel
- Sampling.metal
- Capabilities
- .library
- physicsSubstepsKernel
- Float
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
- Rect
- CaseIterable
- Bool
- FoliageTextures
- DatasetSpec
- SurfaceKind
- .init
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
- Foliage
- same.sh
- Key
- baseline.sh
- BuildingPlan
- Map
- export.py
- Raster.metal
- .stages
- MeshSDF
- lumenCardRadiosityKernel
- TraversalStats
- NeuralUpscaler
- PlantEditorTests
- Kind
- GLTFModel
- RoomType
- .build
- VoxelLOD
- VirtualMesh
- FluidSurface.metal
- RasterClusters.metal
- Shaders.metal
- audit-backlog-2026-10.md
- RenderView
- .load
- VSMCounters
- RasterInstance
- CharacterLibrary
- QuartzCore
- MeshBuilder
- Pipelines
- CodingKeys
- Curve
- Post.metal
- Furnisher
- PlantTracingTests
- DebugPanel
- FurnitureItem
- TraceScene
- Ray
- CoreGraphics
- SDFShape
- related.sh
- SkyParams
- .load
- Hit
- VGParams
- Step 1: safety (A-items), no image change except A3
- .add
- uint
- VSM.metal
- .span
- Metal3Frame
- FloorPlanView
- VSMView
- PlantParam
- VSMClusterArgs
- VSMScene
- uint
- FleshFigure
- Modes
- .buildings
- VSMParams
- FoliageRuntimeTests
- Where things are
- RasterParams
- Role
- RenderPass4
- Neural.metal
- VSMInstance
- ColliderGrid
- train.py
- PlantTracing
- RasterCounters
- CityStyle
- Float
- .simplify
- PhysicsFleshHeader
- SceneShading
- RagdollTests
- .addHair
- Benchmark
- .floatCapture
- NeuralUpscalerTests
- ShadingPoint
- Terrain
- PhysicsConstraint
- PhysicsGroup
- PhysicsFleshFibre
- PhysicsPair
- PhysicsPoseParams
- Instance
- VSMLight
- Build the graph when it's missing
- ensure-graph.sh
- video.sh
- PlantSpecies.swift
- traceKernel
- FBXFile
- RasterScene
- WorldPlace
- LumenParams
- XCTestCase
- SkyImage
- DenoisingUpscaler
- RenderThread
- .xyz
- DebugInfo
- HairBSDF
- .commit
- Config
- Clip
- PhysicsParams
- Heavens
- Double
- CameraTrack
- Key
- .forestcheck
- Stage
- PlantEditorPanel
- lumen.py
- .building
- Buffer
- LoadingOverlay
- PressButton
- Clip
- KernelVariantsTests
- Kind
- LumenRadiosityParams
- PhysicsMuscle
- BuildingEditorPanel
- FoliageVoxels
- FluidSurface
- vsmFragment
- PhysicsFleshPin
- SDFBox
- Kind
- .encoder
- PhysicsGrab
- TrainingSceneTests
- RTVoxels
- Host
- Kind
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
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `What to look for` --references--> `ComputePass`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Sources/MetalRenderer/ComputePass.swift
- `4. Divergence and memory access patterns` --references--> `clusterWalk()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Intersect.metal
- `Pass 1: tile cull (`megaLightsCullKernel`)` --references--> `megaLightsCullKernel()`  [INFERRED]
  .claude/memory/plans/megalights.md → Sources/MetalRenderer/Shaders/MegaLights.metal

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

## Communities (277 total, 48 thin omitted)

### Community 0 - "Scene"
Cohesion: 0.04
Nodes (35): Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6), GPUEmissiveTriangle, meshLights, Assembly, Bone, BorrowedLight, BorrowedMesh, CityLight (+27 more)

### Community 1 - "MetalGI Real-Time Ray Tracer"
Cohesion: 0.05
Nodes (40): AMD FidelityFX Shadow Denoiser, Benchmark Mode (METALGI_BENCH, Benchmark.swift), Void-and-Cluster Blue-Noise Sampling, Cluster LOD DAG (128-triangle clusters), compositeKernel (unshadowed light x visibility + indirect, ACES), Cornell Room Scene, EA SEED GIBS, Per-Frame GPU Pass Pipeline (+32 more)

### Community 2 - "GLTFLoader"
Cohesion: 0.16
Nodes (24): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+16 more)

### Community 3 - "RenderSettings"
Cohesion: 0.07
Nodes (62): Integration (follow the ReSTIR wiring; refactor-skill rules), Clipboard, FacadeDef, InteriorDef, MassingDef, Programme, Proportions, Span (+54 more)

### Community 4 - "Lights.metal"
Cohesion: 0.07
Nodes (58): Design, Light influence range (new; nothing in the codebase has a cutoff), Pass 1: tile cull (`megaLightsCullKernel`), Pass 2: sample + trace (`megaLightsSampleKernel`), Pass 3: resolve (`megaLightsResolveKernel`, full res), clipSegment(), groupElement(), groupMask() (+50 more)

### Community 5 - "Lift"
Cohesion: 0.10
Nodes (16): Door, .colliders, .frame, InteriorControls, .obstacles, Prop, Switch, Lift (+8 more)

### Community 6 - "PlantCatalog"
Cohesion: 0.11
Nodes (12): .savedDef, PlantCatalog, .count, .covers, File, Foliage.SpeciesDef, .fingerprint, .launch (+4 more)

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
Cohesion: 0.09
Nodes (13): PlantEditorHost, PlantEditorModel, .def, .inWorkshop, .isBuiltIn, .isDirty, .key, .species (+5 more)

### Community 11 - "SettingsTableTests"
Cohesion: 0.07
Nodes (15): Settings: `SettingsTable.swift`, The pass, The pass after a feature, The report and the commit message, What stays fixed, What to look for, base, SkyMode (+7 more)

### Community 12 - "rcTraceMergeKernel"
Cohesion: 0.10
Nodes (19): Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures), Checklist: per-frame CPU / encoding (details: [references/cpu-swift.md](references/cpu-swift.md)), Performance in MetalRenderer, The loop, rcClearAmbientKernel(), rcEvalSH() (+11 more)

### Community 13 - "FluidSystem"
Cohesion: 0.09
Nodes (22): .surfaceCapacity, GPUFluidSurface, FluidSystem, .capacity, .cell, .dims, .domain, .mass (+14 more)

### Community 14 - "HairTests"
Cohesion: 0.13
Nodes (4): BoxData, SDFBuffers, .buffers, HairTests

### Community 16 - "translate"
Cohesion: 0.15
Nodes (11): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, .gpu, LightPose, Kit, Stand (+3 more)

### Community 18 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.16
Nodes (15): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 5. Reductions, atomics and threadgroup memory, 7. Acceleration structures and ray tracing, 8. Pipelines and resources, GPU (Metal / MSL) practices for MetalRenderer (+7 more)

### Community 19 - "Fog.metal"
Cohesion: 0.15
Nodes (25): fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel(), fogMedium() (+17 more)

### Community 20 - "pcgHash"
Cohesion: 0.05
Nodes (67): boneAngle(), bucketPhase(), coverLean(), meanGust(), partBones(), partDirection(), partPoint(), partWind() (+59 more)

### Community 21 - "pathTraceKernel"
Cohesion: 0.05
Nodes (61): distance, makeRay(), pathTraceKernel(), PathTraceParams, bounds, config, samples, ptEval() (+53 more)

### Community 22 - "LightTable"
Cohesion: 0.28
Nodes (8): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount, LightMotion, animated, constant, scaleOnly

### Community 23 - "float4x4"
Cohesion: 0.15
Nodes (10): float4x4, Hall, Loop, .length, Props, Zone, factory, garage (+2 more)

### Community 24 - "Int"
Cohesion: 0.03
Nodes (34): Batch 5: per-frame CPU, Detail, flat, full, Ends, Faces, Params, RasterClusters (+26 more)

### Community 25 - "lightType"
Cohesion: 0.12
Nodes (33): lightType(), diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate (+25 more)

### Community 26 - "SkinnedCharacter"
Cohesion: 0.11
Nodes (13): GPUJoint, .parent, GPUJointMatrix, Clip, .duration, .loopKeys, Level, .triangleCount (+5 more)

### Community 27 - "lumenTraceKernel"
Cohesion: 0.21
Nodes (15): lumenCullKernel(), lumenDirection(), lumenDirectionJitter(), lumenFilterKernel(), lumenHZBKernel(), lumenProbeKernel(), lumenResolveKernel(), LumenScreenHit (+7 more)

### Community 28 - "Kernel"
Cohesion: 0.01
Nodes (141): Kernel, accumulate, accumulateColor, atrous, bloomDown, bloomUp, cloudNoise, cloudShadow (+133 more)

### Community 29 - "SettingsPanel"
Cohesion: 0.08
Nodes (13): Sides, backToBack, corner, free, row, .title, Action, FlippedView (+5 more)

### Community 30 - "Renderer"
Cohesion: 0.04
Nodes (61): D. Structure / duplication, Denoise, 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, MetalKit, ComputeStage, FogNoise, GPUPostParams (+53 more)

### Community 31 - ".init"
Cohesion: 0.20
Nodes (7): GPUMesh, Kind, arrays, block, clusters, skip, virtual

### Community 32 - "BuildingAssembler"
Cohesion: 0.18
Nodes (6): BuildingAssembler, Cell, .center, .width, Opening, .outerThickness

### Community 33 - "restirTemporalKernel"
Cohesion: 0.13
Nodes (17): shadowOrigin(), emptyReservoir(), packReservoir(), Reservoir, element, M, uv, visible (+9 more)

### Community 34 - "restirGIInitialKernel"
Cohesion: 0.10
Nodes (32): emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng, p (+24 more)

### Community 35 - ".stages"
Cohesion: 0.14
Nodes (7): B. Remaining per-frame CPU, Backlog: the rest of the audit, E. Load time, Cascade, RadianceCascades, RCParams, RCPipelines

### Community 36 - "SIMD4"
Cohesion: 0.08
Nodes (35): GPUFleshFibre, GPUFleshHeader, GPUFleshPin, GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUHairGroup, GPUInstanceData (+27 more)

### Community 37 - "3D Scene Composition"
Cohesion: 0.27
Nodes (9): 3D Scene Composition, Blue Sphere, Gradient Background, Gray Geometric Boxes, Green Tilted Rectangular Plane, Red Tilted Rectangular Plane, White Rounded Rectangle Pillar, White Sphere (+1 more)

### Community 38 - "GeneratedCache"
Cohesion: 0.10
Nodes (9): CryptoKit, GeneratedCache, Hasher, SectionFile, Stored, .array, .count, mapped (+1 more)

### Community 39 - "Physics.metal"
Cohesion: 0.15
Nodes (41): physCell(), physColourPairs(), physColoursAround(), physDirection(), physDistance2(), physFlat(), physHash(), physicsClearKernel() (+33 more)

### Community 40 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 41 - ".write"
Cohesion: 0.10
Nodes (14): LeafAnchor, LeafShape, blade, kite, needle, Phyllotaxis, distichous, spiral (+6 more)

### Community 42 - "String"
Cohesion: 0.03
Nodes (79): CatalogRegistry, Section, Frame, DirectLightMode, auto, exact, grouped, megalights (+71 more)

### Community 43 - "VSMTargets"
Cohesion: 0.07
Nodes (16): GPULight, GPUVSMView, GPULightTreeNode, LightTree, .byteCount, Kind, sphere, spot (+8 more)

### Community 44 - "SceneBuffers"
Cohesion: 0.06
Nodes (21): .empty, RTPart, LoadOptions, .instanceScratch, .loadOptions, .namedBlocks, .namedInstanceBlocks, .namedPrimitives (+13 more)

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
Cohesion: 0.14
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 50 - ".part"
Cohesion: 0.16
Nodes (11): FBXError, .description, CharacterImporter, concurrently(), Mapping, controlPoint, polygonVertex, Skeleton (+3 more)

### Community 51 - "SIMD3"
Cohesion: 0.05
Nodes (18): Darwin, GPULumenClipLevel, LumenGlobalSDF, .isComplete, .megabytes, Camera, .forward, rotate() (+10 more)

### Community 52 - "SceneSettings"
Cohesion: 0.04
Nodes (50): Building editor: handoff (2026-10-08), Checked in the window (M1 Max, Oct 8), M1 Max numbers, Not checked anywhere, To do on the M4 Max, SceneKind, area, buildings (+42 more)

### Community 53 - "3D Geometric Test Scene"
Cohesion: 0.29
Nodes (7): Box Geometric Primitive, Cube Geometric Primitive, Global Illumination and Reflections, Colored Materials, 3D Geometric Test Scene, Sphere Geometric Primitive, Ray Tracing Stress Test Reference

### Community 54 - "ProceduralTextures"
Cohesion: 0.18
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
Nodes (31): .programme, BodyMarks, BodySurface, .bounds, Mark, Muscle, MuscleAtlas, Place (+23 more)

### Community 60 - "Types.metal"
Cohesion: 0.06
Nodes (38): EmissiveTriangle, e1, e2, uv12, v0, FogParams, albedo, counts (+30 more)

### Community 61 - "reflectionKernel"
Cohesion: 0.04
Nodes (82): ggxFromDirection(), lightSpecular(), reflectionHitRadiance(), reflectionKernel(), bindLightSampling(), bindShading(), catmullRom(), catmullRomTangent() (+74 more)

### Community 62 - "VGBlas"
Cohesion: 0.10
Nodes (19): VGBlas, attrs, pad0, pad1, pad2, triangles, tris, VGClusterView (+11 more)

### Community 63 - "InstanceData"
Cohesion: 0.10
Nodes (19): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform (+11 more)

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
Cohesion: 0.14
Nodes (6): .current, .virtualGeometryChanged, VirtualTracing, .extraInstances, .pool, .summary

### Community 73 - "CityPlan"
Cohesion: 0.05
Nodes (37): .entry, .well, Core, .all, .stairPlan, Mode, backCore, frontCore (+29 more)

### Community 74 - "PhysicsWorld"
Cohesion: 0.08
Nodes (14): Int32, GPUFluidParams, GPUFluidParticle, GPUPhysicsParticle, Cloth, PhysicsWorld, .buckets, .cellSize (+6 more)

### Community 77 - "RendererController"
Cohesion: 0.12
Nodes (11): .buildingPlan, .buildingStats, .cameraPosition, .walker, .plantStats, RendererController, .debugActive, .debugInfo (+3 more)

### Community 78 - "TextureStreamer"
Cohesion: 0.07
Nodes (16): LoadStep, .materialBuffers, Entry, Level, SparseMapping, TextureStreamer, .details, .levelProgress (+8 more)

### Community 79 - "RasterVGParams"
Cohesion: 0.11
Nodes (17): RasterMeshVertex, RasterVGParams, capacity, flags, frame, instanceCount, lodCam, pad (+9 more)

### Community 80 - "KernelVariants"
Cohesion: 0.20
Nodes (5): Pipelines: `Pipelines.swift`, finish, .function, KernelVariants, .count

### Community 81 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 82 - "LoadActivity"
Cohesion: 0.12
Nodes (11): Job, .heading, LoadActivity, .onChange, LoadJob, .isCancelled, .isCancelled, Snapshot (+3 more)

### Community 83 - "LumenSDF.metal"
Cohesion: 0.08
Nodes (38): lumenClipContains(), lumenClipDistance(), LumenClipLevel, origin, voxel, lumenClipTexel(), lumenFieldAlbedo(), lumenGlobalBinKernel() (+30 more)

### Community 84 - "Intersect.metal"
Cohesion: 0.19
Nodes (15): assumeCurveShape(), boxCandidate(), clusterWalk(), CurveLevels, Levels, Levels<false>, Levels<true>, octDecode() (+7 more)

### Community 85 - ".buildWorld"
Cohesion: 0.15
Nodes (7): Batch 6: load time, SurfaceMaterial, .uvScale, Prop, BuildingStats, WalkArea, BuildingKit

### Community 86 - "BuildingEditorModel"
Cohesion: 0.04
Nodes (37): Where things are, interior, BuildingEditorHost, BuildingEditorModel, .currentOverride, .currentRef, .def, .inWorkshop (+29 more)

### Community 87 - "Sampling.metal"
Cohesion: 0.07
Nodes (29): quantizeUV(), regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw(), regirLookup() (+21 more)

### Community 88 - "Capabilities"
Cohesion: 0.20
Nodes (5): Capabilities: `Capabilities.swift`, Capabilities, .summary, CapabilitiesTests, .none

### Community 89 - ".library"
Cohesion: 0.08
Nodes (21): Age, mature, sapling, young, Bone, Part, Plant, .height (+13 more)

### Community 90 - "physicsSubstepsKernel"
Cohesion: 0.21
Nodes (23): quatMul(), quatRotate(), physActivate(), physAnchorTurnWeight(), physConj(), physDampJoint(), physHold(), physicsSubstepsKernel() (+15 more)

### Community 91 - "Float"
Cohesion: 0.16
Nodes (5): Choice, Finish, MaterialDef, Palette, StyleDraw

### Community 92 - "flagOn"
Cohesion: 0.20
Nodes (14): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), compositeKernel(), debugHashColor(), debugHeat(), finiteSample() (+6 more)

### Community 93 - "Upscaler"
Cohesion: 0.16
Nodes (3): UpscaleInputs, Upscaler, View

### Community 94 - "megaLightsSampleKernel"
Cohesion: 0.09
Nodes (37): cosSubClamped(), inwardPlane(), lightTreeImportance(), LightTreeNode, axis, hi, link, lo (+29 more)

### Community 95 - "Metal3Pass"
Cohesion: 0.16
Nodes (3): Metal3Pass, .declarationScope, FluidTests

### Community 96 - "Crowd.metal"
Cohesion: 0.05
Nodes (45): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdPoseKernel(), CrowdPoseParams, firstSlot, jointBase (+37 more)

### Community 99 - "Building"
Cohesion: 0.05
Nodes (39): Building, BuildingGenerator, BuildingSpec, .style, BuildingTier, .top, Footprint, .area (+31 more)

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

### Community 104 - "Rect"
Cohesion: 0.16
Nodes (9): PlanDoor, PlanRoom, .area, StoreyPlanner, Rect, .center, .size, PlanEdit (+1 more)

### Community 105 - "CaseIterable"
Cohesion: 0.03
Nodes (81): Tab, facade, floors, furnish, look, massing, rooms, site (+73 more)

### Community 106 - "Bool"
Cohesion: 0.04
Nodes (56): NeuralError, format, memory, .reservoirCount, Bool, .envText, Control, checkbox (+48 more)

### Community 107 - "FoliageTextures"
Cohesion: 0.15
Nodes (10): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+2 more)

### Community 108 - "DatasetSpec"
Cohesion: 0.18
Nodes (10): CameraDrift, ClipStyle, held, moving, paused, DatasetClip, DatasetFrame, .cameraPose (+2 more)

### Community 109 - "SurfaceKind"
Cohesion: 0.12
Nodes (12): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+4 more)

### Community 110 - ".init"
Cohesion: 0.05
Nodes (11): To do on the M4 Max, Launch, done, PreparedScene, .plantSeasonChanged, .settings, .windFrame, resourceCreation (+3 more)

### Community 111 - "CurveEditor"
Cohesion: 0.15
Nodes (10): CurveEditor, .canvas, .points, .presetTitle, EditorDrag, EditorDragKey, EnvironmentValues, .editorDrag (+2 more)

### Community 112 - "WorldTile"
Cohesion: 0.10
Nodes (12): GPUMaterial, .time, Assembler, Chunk, .triangles, ChunkRecord, Draft, Light (+4 more)

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
Cohesion: 0.15
Nodes (7): tensors, NeuralWeights, .factor, .headChannels, .kernelHead, .stateChannels, .wantsSplit

### Community 118 - "Interior"
Cohesion: 0.13
Nodes (13): Collider, Door, Finishes, .ceilingMaterial, Interior, InteriorBuilder, LiftShaft, Maker (+5 more)

### Community 119 - "AABB"
Cohesion: 0.11
Nodes (10): AABB, .area, .centroid, .isEmpty, .bounds, LocalIds, MeshClusterizer, TextureSource (+2 more)

### Community 120 - "VirtualBLAS"
Cohesion: 0.16
Nodes (11): Built, CutInput, Entry, VirtualBLAS, .instanceCount, .isBusy, .meshCount, .sourceTriangles (+3 more)

### Community 121 - "Foliage"
Cohesion: 0.08
Nodes (16): Card, Foliage, Grower, Skeleton, Stem, Flora, .geometry, .index (+8 more)

### Community 122 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 123 - "Key"
Cohesion: 0.12
Nodes (11): Keys, hi, lo, Foliage.Curve, Key, crown, linear, points (+3 more)

### Community 125 - "BuildingPlan"
Cohesion: 0.26
Nodes (3): DemoWalk, Point, BuildingPlan

### Community 126 - "Map"
Cohesion: 0.12
Nodes (7): Map, BlueNoise, .cacheURL, SplitMix64, CacheFile, MaterialTextures, CacheTests

### Community 127 - "export.py"
Cohesion: 0.13
Nodes (11): row(), golden(), main(), write_nnw(), chw(), main(), run_clip(), guides() (+3 more)

### Community 128 - "Raster.metal"
Cohesion: 0.21
Nodes (15): atomic_uint* rasterTraced(device RasterCounters* counters)(), hzbInitKernel(), hzbReduceKernel(), rasterBoundsKernel(), rasterBoxVisible(), rasterChunksKernel(), rasterClip(), rasterCorner() (+7 more)

### Community 129 - ".stages"
Cohesion: 0.09
Nodes (8): Lumen, LumenParams, LumenPipelines, LumenRadiosityParams, Card, GPULumenCard, LumenCards, .megabytes

### Community 130 - "MeshSDF"
Cohesion: 0.14
Nodes (11): Baked, bricks, heights, Heightfield, .hi, MeshSDF, .bytes, .hi (+3 more)

### Community 131 - "lumenCardRadiosityKernel"
Cohesion: 0.16
Nodes (14): LumenCard, atlas, hi, lo, lumenCardCaptureKernel(), lumenCardCombineKernel(), lumenCardLightKernel(), lumenCardPoint() (+6 more)

### Community 132 - "TraversalStats"
Cohesion: 0.11
Nodes (8): 9. Shader helpers: use them, don't copy, .instanceAS, Content, TraceSceneArgs, TraversalStats, .description, .line, .rays

### Community 133 - "NeuralUpscaler"
Cohesion: 0.20
Nodes (7): GPUNeuralParams, NeuralInputs, NeuralPipelines, NeuralUpscaler, .factor, .outputHeight, .outputWidth

### Community 134 - "PlantEditorTests"
Cohesion: 0.11
Nodes (3): PlantMutate, Host, PlantEditorTests

### Community 135 - "Kind"
Cohesion: 0.06
Nodes (34): Kind, armchair, basin, bath, bed, bench, bookcase, boxes (+26 more)

### Community 136 - "GLTFModel"
Cohesion: 0.23
Nodes (7): GLTFModel, .triangleCount, Light, Mesh, Entry, File, PropLibrary

### Community 137 - "RoomType"
Cohesion: 0.06
Nodes (37): CityPlan.Rect, .area, FloorPlan, .height, RoomType, backroom, bath, bedroom (+29 more)

### Community 139 - "VoxelLOD"
Cohesion: 0.11
Nodes (6): TLASUpdate, .descriptor, .descriptor4, Entry, VoxelLOD, .megabytes

### Community 140 - "VirtualMesh"
Cohesion: 0.15
Nodes (7): Cluster, Group, .isRoot, VGCluster, VirtualGeometryBuilder, VirtualMesh, VGStreamerTests

### Community 141 - "FluidSurface.metal"
Cohesion: 0.37
Nodes (12): fluidCorner(), fluidSurfaceBlurKernel(), fluidSurfaceCell(), fluidSurfaceClearKernel(), fluidSurfaceCoords(), fluidSurfaceCountKernel(), fluidSurfaceEdges(), fluidSurfaceNode() (+4 more)

### Community 142 - "RasterClusters.metal"
Cohesion: 0.23
Nodes (11): rasterClusterMesh(), RasterInstance* rvgRecords(device atomic_uint* state)(), RasterMeshPrimitive, rasterVGCutKernel(), rasterVGMeshArgsKernel(), rasterVGRetestKernel(), rvgDraw(), rvgOwners() (+3 more)

### Community 143 - "Shaders.metal"
Cohesion: 0.08
Nodes (9): Where things are, glassKernel(), glassReflection(), liquidApplyKernel(), liquidFresnel(), liquidHighlights(), liquidKernel(), liquidMaterial() (+1 more)

### Community 144 - "audit-backlog-2026-10.md"
Cohesion: 0.12
Nodes (6): 1. Make the dataset, 2. Train, 3. Use it in the app, Our own denoising upscaler, Setup, Status (Oct 2026)

### Community 145 - "RenderView"
Cohesion: 0.05
Nodes (11): FrameOutput, LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title, OffscreenSurface (+3 more)

### Community 146 - ".load"
Cohesion: 0.18
Nodes (3): Failure, ShaderSource, ShaderSourceTests

### Community 147 - "VSMCounters"
Cohesion: 0.09
Nodes (21): VSMCounters, baseInstance, clearBaseInstance, clearVertexCount, clearVertexStart, cullX, cullY, cullZ (+13 more)

### Community 148 - "RasterInstance"
Cohesion: 0.14
Nodes (12): rasterFragment(), RasterInstance, corners, indices, w, x, y, RasterMesh (+4 more)

### Community 149 - "CharacterLibrary"
Cohesion: 0.29
Nodes (4): BlobReader, BlobWriter, CharacterLibrary, .directory

### Community 150 - "QuartzCore"
Cohesion: 0.09
Nodes (6): AppKit, Combine, MetalFX, QuartzCore, Array, Headless

### Community 151 - "MeshBuilder"
Cohesion: 0.17
Nodes (6): .triangleCount, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount

### Community 152 - "Pipelines"
Cohesion: 0.05
Nodes (28): Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, ComputePass, FrameEncoder, PrimitiveRefit, PrimitiveWork, .encoderCount, RenderAttachments, GPURasterParams (+20 more)

### Community 153 - "CodingKeys"
Cohesion: 0.18
Nodes (11): Arch, CodingKeys, arch, factor, guides, head, hidden, inputs (+3 more)

### Community 154 - "Curve"
Cohesion: 0.15
Nodes (14): Crown, conical, cylindrical, flame, hemispherical, spherical, Curve, crown (+6 more)

### Community 155 - "Post.metal"
Cohesion: 0.29
Nodes (11): bloomDownKernel(), bloomPrefilter(), bloomUpKernel(), circleOfConfusion(), dofKernel(), finishKernel(), focusKernel(), karisWeight() (+3 more)

### Community 156 - "Furnisher"
Cohesion: 0.14
Nodes (11): Furnisher, FurnishPalette, Light, Prefer, any, away, corner, middle (+3 more)

### Community 158 - "DebugPanel"
Cohesion: 0.09
Nodes (7): F. Housekeeping, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, cpu

### Community 160 - "TraceScene"
Cohesion: 0.11
Nodes (16): TraceScene, clusterInstance, clusters, cutouts, indices, meshes, pad, parts (+8 more)

### Community 161 - "Ray"
Cohesion: 0.19
Nodes (19): anyHit(), assumeCurves(), candidate(), closestDistance(), closestHit(), countedHit(), countedQuery(), intersectAny() (+11 more)

### Community 162 - "CoreGraphics"
Cohesion: 0.17
Nodes (3): CoreGraphics, ImageIO, UniformTypeIdentifiers

### Community 163 - "SDFShape"
Cohesion: 0.12
Nodes (18): Node, .transform, Op, intersect, subtract, union, Primitive, box (+10 more)

### Community 164 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 165 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 166 - ".load"
Cohesion: 0.19
Nodes (7): GLTFError, .description, invalid, unsupported, Image, Material, TextureRef

### Community 167 - "Hit"
Cohesion: 0.17
Nodes (10): committedCurve(), Hit, barycentrics, cluster, hit, instance, part, primitive (+2 more)

### Community 168 - "VGParams"
Cohesion: 0.08
Nodes (28): vgBoxesKernel(), VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere (+20 more)

### Community 169 - "Step 1: safety (A-items), no image change except A3"
Cohesion: 0.07
Nodes (25): Context, Earlier plan (done on 2026-10-03): safety fixes + market CPU wins, Step 1: safety (A-items), no image change except A3, Step 2: cheap per-frame and load wins, Verification, 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), 3. Parallelism, 4. CPU↔GPU data layout (+17 more)

### Community 170 - ".add"
Cohesion: 0.32
Nodes (3): Hash, .value, PlantGoldenTests

### Community 171 - "uint"
Cohesion: 0.29
Nodes (10): candidateIndex(), candidatePart(), card(), commitCurve(), commitCurveCandidate(), committed(), committedPart(), instance() (+2 more)

### Community 172 - "VSM.metal"
Cohesion: 0.23
Nodes (14): shadowVisible(), vsmBoxPages(), vsmClip(), vsmClipLocal(), vsmCullKernel(), vsmDebugKernel(), vsmEntry(), vsmFootprint() (+6 more)

### Community 174 - "Metal3Frame"
Cohesion: 0.13
Nodes (3): Metal3Frame, GPUProfiler, .passProfilingSupported

### Community 175 - "FloorPlanView"
Cohesion: 0.12
Nodes (16): FloorPlanView, .body, .help, .picked, .status, .storeys, .toolbar, Mapping (+8 more)

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

### Community 181 - "FleshFigure"
Cohesion: 0.10
Nodes (14): GPUSoftVertex, .cells, Flesh, FleshOptions, MuscleSpec, Side, back, front (+6 more)

### Community 182 - "Modes"
Cohesion: 0.10
Nodes (17): Batch 1: shader file split, Batch 2: shader duplication, Batch 4: small GPU items, Batch 7: housekeeping, C. GPU, Context, MetalGI: the rest of the audit backlog, in seven batches, Not in this plan (+9 more)

### Community 183 - ".buildings"
Cohesion: 0.18
Nodes (7): Batch 3: launch time, Offscreen rendering in MetalRenderer, Recipes, Render something: `scripts/render.sh`, Rules, What headless changes, and what it doesn't, Reading the table

### Community 184 - "VSMParams"
Cohesion: 0.15
Nodes (13): VSMParams, budget, entries, flags, frame, instanceCount, keep, maxDraws (+5 more)

### Community 186 - "Where things are"
Cohesion: 0.14
Nodes (9): M1 Max numbers, Not checked anywhere, Plant editor: handoff to the M4 Max (2026-10-08), Where things are, Habitat, Ramp, TreePicker, .isEmpty (+1 more)

### Community 187 - "RasterParams"
Cohesion: 0.17
Nodes (12): RasterParams, chunkCount, firstAssembly, flags, hzbLevels, hzbSize, instanceCount, maxDraws (+4 more)

### Community 188 - "Role"
Cohesion: 0.08
Nodes (24): Role, book0, book1, book2, book3, carton, ceramic, chrome (+16 more)

### Community 190 - "Neural.metal"
Cohesion: 0.16
Nodes (15): neuralConvKernel(), neuralCubic(), neuralCubicFar(), neuralCubicNear(), neuralFinishKernel(), neuralKernelFinishKernel(), neuralLogLight(), NeuralParams (+7 more)

### Community 191 - "VSMInstance"
Cohesion: 0.18
Nodes (10): VSMInstance, corners, indices, meshIndex, pages, view, w, x (+2 more)

### Community 192 - "ColliderGrid"
Cohesion: 0.26
Nodes (6): ColliderGrid, Input, Moving, Walker, .eyePosition, .height

### Community 193 - "train.py"
Cohesion: 0.10
Nodes (7): augment(), Sequences, display(), loss_fn(), step(), masked_l1(), run_sequence()

### Community 194 - "PlantTracing"
Cohesion: 0.07
Nodes (14): Tests, PlantTracing, .instanceOptions, .workItems, Refit, .encoderCount, Wind, PlantKey (+6 more)

### Community 195 - "RasterCounters"
Cohesion: 0.20
Nodes (9): RasterCounters, baseInstance, groups, groupsX, groupsY, groupsZ, instanceCount, vertexCount (+1 more)

### Community 196 - "CityStyle"
Cohesion: 0.18
Nodes (9): .name, CityStyle, mixed, modern, office, oldtown, residential, .title (+1 more)

### Community 197 - "Float"
Cohesion: 0.12
Nodes (6): GPUPhysicsShape, PhysicsJoint, PhysicsJointKind, ball, hinge, ShapeBuild

### Community 199 - "PhysicsFleshHeader"
Cohesion: 0.18
Nodes (13): PhysicsFleshHeader, at, at2, counts, more, PhysicsTet, compliance, damping (+5 more)

### Community 200 - "SceneShading"
Cohesion: 0.11
Nodes (16): InstanceBlockRef, records, MaterialTexture, t, SceneShading, cloudShadow, emissive, feedback (+8 more)

### Community 203 - "Benchmark"
Cohesion: 0.08
Nodes (12): Benchmark, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture, .shouldRecord (+4 more)

### Community 204 - ".floatCapture"
Cohesion: 0.16
Nodes (3): DatasetCapture, inputs, reference

### Community 206 - "ShadingPoint"
Cohesion: 0.20
Nodes (10): ShadingPoint, albedo, f0, hair, n, ng, p, roughness (+2 more)

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

### Community 213 - "Instance"
Cohesion: 0.12
Nodes (6): Instance, .isGeometry, .isStatic, .moves, InstanceGroup, SceneBuffersTests

### Community 214 - "VSMLight"
Cohesion: 0.40
Nodes (5): VSMLight, firstView, kind, levels, pad

### Community 215 - "Build the graph when it's missing"
Cohesion: 0.50
Nodes (3): Build the graph when it's missing, Rules, Run it: `scripts/ensure-graph.sh`

### Community 218 - "PlantSpecies.swift"
Cohesion: 0.27
Nodes (3): Foliage.Phyllotaxis, FoliageTextures.Kind, .all

### Community 219 - "traceKernel"
Cohesion: 0.08
Nodes (44): 3. Occupancy and registers: the default suspect for big kernels, hairFresnel(), hairFromGBuffer(), hairI0(), hairLightDirection(), hairLogI0(), hairLogistic(), hairLogisticCDF() (+36 more)

### Community 220 - "FBXFile"
Cohesion: 0.10
Nodes (13): Compression, Children, Connection, Contents, FBXArrayElement, invalid, unsupported, FBXFile (+5 more)

### Community 221 - "RasterScene"
Cohesion: 0.28
Nodes (3): RasterScene, .megabytes, RasterTargets

### Community 223 - "LumenParams"
Cohesion: 0.25
Nodes (6): LumenParams, grid, options, screen, sdf, tuning

### Community 224 - "XCTestCase"
Cohesion: 0.21
Nodes (3): GLTFLoaderTests, PipelineCacheTests, StressSceneTests

### Community 225 - "SkyImage"
Cohesion: 0.16
Nodes (5): Atmosphere, LoadError, unreadable, SkyImage, volume

### Community 226 - "DenoisingUpscaler"
Cohesion: 0.18
Nodes (3): conv(), DenoisingUpscaler, warp()

### Community 228 - ".xyz"
Cohesion: 0.06
Nodes (20): GPUHairParams, GPUHairStrand, GPUHairVertex, GPUPhysicsBody, GPUPhysicsContact, GPUPhysicsParams, .right, .up (+12 more)

### Community 229 - "DebugInfo"
Cohesion: 0.22
Nodes (7): Step 0: baseline and a CPU meter, DebugInfo, VirtualGeometry, blas, clusters, off, .triangles

### Community 232 - "Config"
Cohesion: 0.07
Nodes (3): Benchmark modes: `Benchmark+Modes.swift`, Config, ShowcaseLook

### Community 233 - "Clip"
Cohesion: 0.29
Nodes (7): Clip, facade, furnish, look, massing, plan, rooms

### Community 235 - "PhysicsParams"
Cohesion: 0.18
Nodes (11): PhysicsParams, cloth, counts, gravity, grid, particleGrid, particles, rolling (+3 more)

### Community 236 - "Heavens"
Cohesion: 0.33
Nodes (6): Heavens, .adaptation, .light, .lightIsMoon, .stars, .sunElevation

### Community 237 - "Double"
Cohesion: 0.09
Nodes (13): Double, World, .anchorTile, .start, Block, City, Flora, Ground (+5 more)

### Community 238 - "CameraTrack"
Cohesion: 0.16
Nodes (7): CameraTrack, .duration, Event, callLift, flashlight, lights, Key

### Community 239 - "Key"
Cohesion: 0.48
Nodes (3): Key, PipelineCache, .count

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

### Community 247 - "PressButton"
Cohesion: 0.22
Nodes (3): PressButton, .body, SwiftUI

### Community 248 - "Clip"
Cohesion: 0.25
Nodes (7): Clip, graft, habitat, leaves, level, look, Clipboard

### Community 249 - "KernelVariantsTests"
Cohesion: 0.18
Nodes (5): Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, KernelVariantsTests

### Community 250 - "Kind"
Cohesion: 0.33
Nodes (6): Kind, door, entrance, glazed, lift, open

### Community 251 - "LumenRadiosityParams"
Cohesion: 0.22
Nodes (9): LumenRadiosityParams, cardInstances, frame, levels, on, pad0, pad1, pad2 (+1 more)

### Community 252 - "PhysicsMuscle"
Cohesion: 0.25
Nodes (8): PhysicsMuscle, axisA, axisB, bodyA, bodyB, pad0, pad1, range

### Community 253 - "BuildingEditorPanel"
Cohesion: 0.22
Nodes (3): BuildingEditorPanel, .isVisible, .wasVisible

### Community 255 - "FoliageVoxels"
Cohesion: 0.23
Nodes (5): FoliageVoxels, Grid, Piece, Plant, BoxData

### Community 256 - "FluidSurface"
Cohesion: 0.25
Nodes (6): FluidSurface, dims, field, lo, mesh, triangles

### Community 258 - "PhysicsFleshPin"
Cohesion: 0.29
Nodes (7): PhysicsFleshPin, bodyA, bodyB, compliance, particle, restA, restB

### Community 259 - "SDFBox"
Cohesion: 0.25
Nodes (8): SDFBox, pad0, pad1, pad2, pad3, scene, shape, tag

### Community 260 - "Kind"
Cohesion: 0.33
Nodes (5): Kind, furniture, glass, solid, stair

### Community 261 - ".encoder"
Cohesion: 0.16
Nodes (3): Liquids: handoff to the M4 Max (2026-10-08), M1 Max numbers (whole frame, `METALRENDERER_BENCH_SPLIT=0`), To do on the M4 Max

### Community 262 - "PhysicsGrab"
Cohesion: 0.29
Nodes (7): PhysicsGrab, anchor, body, pad0, pad1, pad2, target

### Community 264 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 266 - "Kind"
Cohesion: 0.50
Nodes (4): Kind, directional, point, spot

### Community 267 - "VGRasterInstance"
Cohesion: 0.40
Nodes (5): VGRasterInstance, groupBase, groupCount, instance, workBase

## Knowledge Gaps
- **1787 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+1782 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 2450 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **48 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Int` connect `Int` to `Scene`, `GLTFLoader`, `RenderSettings`, `Lift`, `PlantCatalog`, `PlantEditorModel`, `SettingsTableTests`, `FluidSystem`, `HairTests`, `Metal4Frame`, `translate`, `LightTable`, `float4x4`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `.init`, `BuildingAssembler`, `.stages`, `SIMD4`, `GeneratedCache`, `.write`, `String`, `VSMTargets`, `SceneBuffers`, `View`, `BVHBuilder`, `Crowd`, `.part`, `SIMD3`, `SceneSettings`, `ProceduralTextures`, `MuscleAtlas`, `LumenScene`, `VirtualTracing`, `CityPlan`, `PhysicsWorld`, `RenderPass`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `.library`, `Upscaler`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `Rect`, `CaseIterable`, `Bool`, `FoliageTextures`, `DatasetSpec`, `SurfaceKind`, `.init`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `Interior`, `AABB`, `VirtualBLAS`, `Foliage`, `BuildingPlan`, `Map`, `.stages`, `MeshSDF`, `TraversalStats`, `NeuralUpscaler`, `PlantEditorTests`, `GLTFModel`, `RoomType`, `.build`, `VoxelLOD`, `VirtualMesh`, `audit-backlog-2026-10.md`, `RenderView`, `QuartzCore`, `MeshBuilder`, `Pipelines`, `CodingKeys`, `Curve`, `Furnisher`, `PlantTracingTests`, `DebugPanel`, `FurnitureItem`, `SDFShape`, `.load`, `.span`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `Modes`, `FoliageRuntimeTests`, `Role`, `RenderPass4`, `ColliderGrid`, `PlantTracing`, `CityStyle`, `Float`, `.simplify`, `RagdollTests`, `.addHair`, `Benchmark`, `.floatCapture`, `NeuralUpscalerTests`, `Terrain`, `Instance`, `FBXFile`, `RasterScene`, `WorldPlace`, `XCTestCase`, `SkyImage`, `.xyz`, `DebugInfo`, `.commit`, `Config`, `.keep`, `Double`, `CameraTrack`, `Key`, `.building`, `Buffer`, `LoadingOverlay`, `.buildForest`, `FoliageVoxels`, `.encoder`, `TrainingSceneTests`, `.init`?**
  _High betweenness centrality (0.293) - this node is a cross-community bridge._
- **Why does `String` connect `String` to `Scene`, `GLTFLoader`, `RenderSettings`, `Lift`, `PlantCatalog`, `PlantEditorModel`, `SettingsTableTests`, `FluidSystem`, `translate`, `Int`, `SkinnedCharacter`, `Kernel`, `SettingsPanel`, `Renderer`, `GeneratedCache`, `.write`, `SceneBuffers`, `View`, `BVHBuilder`, `.part`, `SIMD3`, `SceneSettings`, `MuscleAtlas`, `VirtualTracing`, `RendererController`, `TextureStreamer`, `KernelVariants`, `LoadActivity`, `.buildWorld`, `BuildingEditorModel`, `Capabilities`, `.library`, `Float`, `Upscaler`, `Metal3Pass`, `Rect`, `CaseIterable`, `Bool`, `FoliageTextures`, `DatasetSpec`, `.init`, `CurveEditor`, `WorldTile`, `NeuralWeights`, `AABB`, `VirtualBLAS`, `Foliage`, `Key`, `BuildingPlan`, `Map`, `TraversalStats`, `NeuralUpscaler`, `PlantEditorTests`, `Kind`, `GLTFModel`, `RoomType`, `VoxelLOD`, `VirtualMesh`, `RenderView`, `.load`, `CharacterLibrary`, `Pipelines`, `CodingKeys`, `Curve`, `DebugPanel`, `.load`, `.add`, `.span`, `Metal3Frame`, `FloorPlanView`, `PlantParam`, `FleshFigure`, `Modes`, `Where things are`, `PlantTracing`, `CityStyle`, `Benchmark`, `NeuralUpscalerTests`, `Instance`, `FBXFile`, `SkyImage`, `DebugInfo`, `.commit`, `Config`, `Clip`, `Double`, `Buffer`, `LoadingOverlay`, `PressButton`, `Clip`, `KernelVariantsTests`, `Kind`, `.buildForest`, `FoliageVoxels`, `.encoder`?**
  _High betweenness centrality (0.113) - this node is a cross-community bridge._
- **Why does `SIMD3` connect `SIMD3` to `Scene`, `RenderSettings`, `Lift`, `FluidSystem`, `HairTests`, `translate`, `SDFTests`, `LightTable`, `float4x4`, `Int`, `SkinnedCharacter`, `Renderer`, `BuildingAssembler`, `SIMD4`, `GeneratedCache`, `.write`, `String`, `VSMTargets`, `View`, `BVHBuilder`, `Crowd`, `.part`, `SceneSettings`, `ProceduralTextures`, `MuscleAtlas`, `LumenScene`, `CityPlan`, `PhysicsWorld`, `RendererController`, `.buildWorld`, `.library`, `Float`, `Metal3Pass`, `PhysicsTests`, `MuscleTests`, `Building`, `SoftModel`, `FoliageTextures`, `DatasetSpec`, `CurveEditor`, `WorldTile`, `Interior`, `AABB`, `VirtualBLAS`, `Foliage`, `BuildingPlan`, `.stages`, `MeshSDF`, `GLTFModel`, `.build`, `VoxelLOD`, `VirtualMesh`, `MeshBuilder`, `Furnisher`, `PlantTracingTests`, `FurnitureItem`, `SDFShape`, `.load`, `.add`, `FleshFigure`, `FoliageRuntimeTests`, `Where things are`, `ColliderGrid`, `PlantTracing`, `Float`, `.simplify`, `RagdollTests`, `.addHair`, `Terrain`, `Instance`, `FBXFile`, `WorldPlace`, `SkyImage`, `.xyz`, `HairBSDF`, `Config`, `Heavens`, `Double`, `CameraTrack`, `.forestcheck`, `.building`, `.buildForest`, `FoliageVoxels`, `Host`?**
  _High betweenness centrality (0.110) - this node is a cross-community bridge._
- **Are the 51 inferred relationships involving `SIMD3` (e.g. with `.body` and `.ceilingLights()`) actually correct?**
  _`SIMD3` has 51 INFERRED edges - model-reasoned connections that need verification._
- **Are the 36 inferred relationships involving `Scene` (e.g. with `Batch 6: load time` and `Step 3: static light proxies (B2), direct buffer writes (B3), material slots (A6)`) actually correct?**
  _`Scene` has 36 INFERRED edges - model-reasoned connections that need verification._
- **What connects `PackageDescription`, `.isEmpty`, `.centroid` to the rest of the system?**
  _1787 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Scene` be split into smaller, more focused modules?**
  _Cohesion score 0.039025779803446806 - nodes in this community are weakly interconnected._