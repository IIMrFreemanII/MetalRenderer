# Graph Report - MetalRenderer  (2026-10-04)

## Corpus Check
- 141 files · ~1,042,731 words
- Verdict: corpus is large enough that graph structure adds value.
- Unclassified: 21 file(s) not represented in the graph (top: .glb 11, .fbx 6, (none) 3)

## Summary
- 3948 nodes · 11281 edges · 176 communities (151 shown, 25 thin omitted)
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 1750 edges (avg confidence: 0.85)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `bf3c8489`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- VirtualGeometry
- .buildWorld
- Renderer
- Benchmark
- Foliage
- Kernel
- GLTFLoader
- CityStyle
- evalcommon.py
- Rect
- VoxelLOD
- LightSampling.metal
- Frame
- traceKernel
- SettingsPanel
- AABB
- .drawFrame
- Bool
- BVHTests
- Lights.metal
- RenderSettings
- MTLTexture
- ComputePass
- restirGIInitialKernel
- .init
- Fog.metal
- Upscaler
- Sky Contact Sheet (11 labelled renders of sky / sun lighting conditions)
- SettingsTableTests
- Sky.metal
- .int
- Scene
- SceneKind
- RegirParams
- Tests
- RenderView
- VirtualBLAS
- .meshes
- Config
- BVHBuild.metal
- GPUTypes.swift
- CityPlan
- Uniforms
- Notes for M1 / M2 Macs
- GPUProfiler
- RadianceCascades
- Mesh
- same.sh
- AppDelegate
- simd
- SkinnedCharacter
- Capabilities
- restirTemporalKernel
- reflectionKernel
- Cornell Box Scene (red left wall, green right wall, white floor/ceiling/back wall)
- Intersect.metal
- baseline.sh
- Output.metal
- Gallery Scene (steampunk figurines on a stepped display plinth)
- Pipelines
- SceneBuffers
- .write
- CLAUDE.md
- SIMD4
- Gallery Reference Render: Overview Camera (ref-overview.png)
- Stress Scene Reference Render (direct, 1.5x)
- Cornell-Box-Style Test Scene (viewed from inside, open front)
- Shaders.metal
- Metal3Pass
- RTScene
- RendererController
- Flora
- rcTraceMergeKernel
- RTBlockInstance
- ref-albedo-1.5x.png (stress scene albedo reference render at 1.5x)
- BuildingAssembler
- Double
- Crowd
- Many-light direct illumination: converged ground-truth direct lighting from a large number of small emitters
- EnvVariable
- atrousKernel
- FogParams
- .add
- GI eval reference image ref8 at 0.5x (Cornell-box style render)
- GI reference render ref8 at 1.5x (Cornell-box scene)
- Stress Test Scene: hundreds of scattered coloured cubes and spheres in a pillared room
- SceneShading
- PlantWind
- OffscreenSurface
- SIMD3
- Float
- EmissiveTriangle
- SceneBuffersTests
- SkyParams
- Footprint
- Stress Scene Reference Render (hwrt, final)
- ref-direct-32.png (ReSTIR eval reference render, direct lighting)
- Many-light test scene (hundreds of small emitters in a room of scattered primitives)
- Shadow Eval Reference Image: Direct Lighting (ref-direct.png)
- Stress scene reference render: direct lighting, 32 (ref-direct-32.png)
- Upscale eval reference image: ref-direct (1920x1200 render of Cornell-box test scene)
- RTPart
- BuildingStyle
- GI eval reference image ref8 (indirect, 0.5x)
- ReSTIR eval reference image: direct lighting, 1024 (ref-direct-1024.png)
- ReSTIR eval reference image: direct lighting, 128 (ref-direct-128.png)
- ReSTIR eval reference image: indirect lighting, market scene (ref-indirect-market.png)
- ReSTIR eval reference image: scattering, market scene (ref-scattering-market.png)
- Stress scene reference render: ref8-indirect-32 (indirect lighting eval reference image)
- Stress test scene (pillared room filled with hundreds of floating cubes and spheres)
- ab.sh
- DebugPanel
- FBXError
- MetalRenderer
- SkyImage
- InstanceData
- FoliageTextures
- SurfaceKind
- Metal4Frame
- .library
- FoliageRuntimeTests
- Camera
- VirtualGeometry.metal
- LayerSurface
- Package.swift
- .named
- FoliageVoxels
- FBXFile
- Metal
- Species
- Material
- Types.metal
- Phyllotaxis
- CustomRayTracer
- Crowd.metal
- render.sh
- Measuring MetalRenderer
- Int32
- crowdPoseKernel
- Int
- .sources
- TextureStreamer
- InputHandler
- Map
- PoseSlot
- SettingsStore
- RTInstance
- .simplify
- VGInstance
- CrowdPoseParams
- CrowdSkinParams
- SectionFile
- VGParams
- ShadingPoint
- GPU (Metal / MSL) practices for MetalRenderer
- Custom
- VGCluster
- RTVoxels
- CrowdRefitParams
- uint
- Shape
- Hit
- KernelVariantsTests
- related.sh
- How a frame works
- BuddyAllocator
- VGBlas
- LightTable
- Edge
- Builder
- Crown
- .generate

## God Nodes (most connected - your core abstractions)
1. `Renderer` - 200 edges
2. `Scene` - 178 edges
3. `SIMD3` - 168 edges
4. `Foliage` - 89 edges
5. `Benchmark` - 88 edges
6. `RenderSettings` - 88 edges
7. `Kernel` - 75 edges
8. `Config` - 71 edges
9. `Metal4Frame` - 58 edges
10. `SIMD4` - 53 edges

## Surprising Connections (you probably didn't know these)
- `Launch time` --references--> `Launch`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/CacheFile.swift
- `Hardware ray tracing, MetalFX's denoiser and Metal 4` --references--> `tonemapKernel()`  [INFERRED]
  README.md → Sources/MetalRenderer/Shaders/Output.metal
- `2. Memory bandwidth: the default suspect for screen-space passes` --references--> `sampleMaterial()`  [INFERRED]
  .claude/skills/performance/references/gpu-metal.md → Sources/MetalRenderer/Shaders/Surface.metal
- `The pass` --references--> `SettingsTableTests`  [INFERRED]
  .claude/skills/refactor/SKILL.md → Tests/MetalRendererTests/SettingsTableTests.swift
- `Measuring MetalRenderer` --references--> `Config`  [INFERRED]
  .claude/skills/performance/references/measuring.md → Sources/MetalRenderer/Benchmark.swift

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Cornell Reference Scene Geometry (boxes, cube, spheres)** — tools_eval_refs_hwrt_cornell_ref_final_tall_white_box, tools_eval_refs_hwrt_cornell_ref_final_short_white_box, tools_eval_refs_hwrt_cornell_ref_final_floating_yellow_cube, tools_eval_refs_hwrt_cornell_ref_final_blue_sphere, tools_eval_refs_hwrt_cornell_ref_final_white_sphere [EXTRACTED 1.00]
- **Gallery Close-up Figurine Lineup on the Stepped Plinth** — tools_eval_refs_gallery_ref_closeup_armored_gunner_model, tools_eval_refs_gallery_ref_closeup_twin_tail_gunner_model, tools_eval_refs_gallery_ref_closeup_clockwork_owl_model, tools_eval_refs_gallery_ref_closeup_mechanical_whale_model, tools_eval_refs_gallery_ref_closeup_workbench_model, tools_eval_refs_gallery_ref_closeup_stepped_plinth [EXTRACTED 1.00]
- **Gallery Overview Scene Composition (figures, pedestals, lights, floor, room, workbench)** — tools_eval_refs_gallery_ref_overview_character_model_lineup, tools_eval_refs_gallery_ref_overview_stepped_pedestals, tools_eval_refs_gallery_ref_overview_emissive_sphere_lights, tools_eval_refs_gallery_ref_overview_glossy_floor_reflections, tools_eval_refs_gallery_ref_overview_diffuse_room_enclosure, tools_eval_refs_gallery_ref_overview_bronze_owl_statue, tools_eval_refs_gallery_ref_overview_workbench_with_desk_lamps [EXTRACTED 1.00]
- **Valley Time-of-Day Series (one camera, five sun positions)** — sky_sheet_00_valley_morning, sky_sheet_01_valley_forenoon, sky_sheet_02_valley_noon, sky_sheet_03_valley_afternoon, sky_sheet_04_valley_evening [EXTRACTED 1.00]
- **Stress Scene Composition: Room, Pillars, Primitives and Emissive Lights** — tools_eval_refs_stress_ref_direct_1_5x_cornell_style_room, tools_eval_refs_stress_ref_direct_1_5x_pillars, tools_eval_refs_stress_ref_direct_1_5x_floating_primitives, tools_eval_refs_stress_ref_direct_1_5x_emissive_sphere_lights [EXTRACTED 1.00]
- **Rendering Features Exercised by the Close-up Reference (metal PBR, glossy reflections, diffuse GI)** — tools_eval_refs_gallery_ref_closeup_pbr_metal_materials, tools_eval_refs_gallery_ref_closeup_glossy_reflections, tools_eval_refs_gallery_ref_closeup_soft_diffuse_gi, tools_eval_refs_gallery_ref_closeup_eval_reference_image [INFERRED 0.75]
- **ReSTIR direct-lighting reference setup: many-light scene, emissive lights and converged ground truth** — tools_eval_refs_restir_ref_direct_1024_many_light_test_scene, tools_eval_refs_restir_ref_direct_1024_small_emissive_sphere_lights, tools_eval_refs_restir_ref_direct_1024_converged_direct_lighting_ground_truth, tools_eval_refs_restir_ref_direct_1024_restir_direct_lighting_evaluation [INFERRED 0.75]
- **ReSTIR direct-lighting reference scene: many objects, many small lights, colored walls** — tools_eval_refs_restir_ref_direct_32_many_object_test_scene, tools_eval_refs_restir_ref_direct_32_many_small_emissive_lights, tools_eval_refs_restir_ref_direct_32_red_green_walls, tools_eval_refs_restir_ref_direct_32_soft_direct_shadows [INFERRED 0.75]
- **ReSTIR scattering reference case: market scene, many small emitters, scattered glow** — tools_eval_refs_restir_ref_scattering_market, tools_eval_refs_restir_ref_scattering_market_market_scene, tools_eval_refs_restir_ref_scattering_market_many_small_emitters, tools_eval_refs_restir_ref_scattering_market_scattering_lighting [INFERRED 0.75]
- **Sky Lighting Features Exercised by the Sheet** — sky_sheet_procedural_sky, sky_sheet_cloud_layer, sky_sheet_turbidity, sky_sheet_aerial_perspective, sky_sheet_image_based_sky, sky_sheet_mixed_lighting [INFERRED 0.75]
- **Stress-scene direct-lighting reference: dense object scene, many emissive lights, soft shadows** — tools_eval_refs_stress_ref_direct_32_stress_scene, tools_eval_refs_stress_ref_direct_32_many_small_emissive_lights, tools_eval_refs_stress_ref_direct_32_soft_shadows, tools_eval_refs_stress_ref_direct_32_direct_lighting_reference [INFERRED 0.75]
- **What the ref8-indirect-32 reference frame exercises: dense stress geometry in a coloured-wall room lit by indirect light** — tools_eval_refs_stress_ref8_indirect_32_stress_scene, tools_eval_refs_stress_ref8_indirect_32_cornell_style_room, tools_eval_refs_stress_ref8_indirect_32_indirect_diffuse_lighting, tools_eval_refs_stress_ref8_indirect_32_soft_shadowing [INFERRED 0.75]
- **Lighting phenomena the GI reference image exercises** — tools_eval_refs_gi_ref8_1_5x_color_bleeding, tools_eval_refs_gi_ref8_1_5x_soft_shadows, tools_eval_refs_gi_ref8_1_5x_emissive_sphere_lights, tools_eval_refs_gi_ref8_1_5x_global_illumination_reference [INFERRED 0.75]
- **Many-light stress setup: dense primitives, scattered emitters and a Cornell-style room rendered as a direct-lighting reference** — tools_eval_refs_stress_ref_direct_128_many_small_emissive_lights, tools_eval_refs_stress_ref_direct_128_colored_primitives, tools_eval_refs_stress_ref_direct_128_cornell_style_room, tools_eval_refs_stress_ref_direct_128_direct_lighting_reference [INFERRED 0.75]
- **Light Transport Effects the Reference Exercises** — tools_eval_refs_hwrt_cornell_ref_final_converged_path_traced_global_illumination, tools_eval_refs_hwrt_cornell_ref_final_color_bleeding, tools_eval_refs_hwrt_cornell_ref_final_soft_shadows, tools_eval_refs_hwrt_cornell_ref_final_emissive_sphere_lights [INFERRED 0.85]
- **Lighting Features the Overview Reference Exercises (small emitters, glossy reflection, indirect bounce)** — tools_eval_refs_gallery_ref_overview_emissive_sphere_lights, tools_eval_refs_gallery_ref_overview_glossy_floor_reflections, tools_eval_refs_gallery_ref_overview_diffuse_room_enclosure, tools_eval_refs_gallery_ref_overview_global_illumination [INFERRED 0.85]
- **Components forming the ReSTIR many-light reference scene** — tools_eval_refs_restir_ref_direct_4096_small_emissive_lights, tools_eval_refs_restir_ref_direct_4096_scattered_cubes_and_spheres, tools_eval_refs_restir_ref_direct_4096_cornell_style_room [INFERRED 0.85]
- **ReSTIR direct-lighting reference: many-light scene, emissive spheres and Cornell-style room rendered as ground truth** — tools_eval_refs_restir_ref_direct_128_many_light_test_scene, tools_eval_refs_restir_ref_direct_128_emissive_sphere_lights, tools_eval_refs_restir_ref_direct_128_cornell_style_room, tools_eval_refs_restir_ref_direct_128_direct_lighting_reference [INFERRED 0.85]
- **Direct-Lighting Shadow Test Setup: lights, occluders and resulting soft shadows in the Cornell-box scene** — tools_eval_refs_shadow_ref_direct_emissive_sphere_lights, tools_eval_refs_shadow_ref_direct_occluder_objects, tools_eval_refs_shadow_ref_direct_soft_shadows, tools_eval_refs_shadow_ref_direct_cornell_box_scene [INFERRED 0.85]
- **Courtyard Sky Comparison (turbidity 5, turbidity 20, image sky on the same view)** — sky_sheet_07_sun_t5, sky_sheet_08_sun_t20, sky_sheet_10_image_sky, sky_sheet_courtyard_scene [INFERRED 0.85]
- **GI phenomena the reference image exercises: emissive lights, color bleeding, soft shadows in a Cornell box** — tools_eval_refs_gi_ref8_0_5x_emissive_sphere_lights, tools_eval_refs_gi_ref8_0_5x_color_bleeding, tools_eval_refs_gi_ref8_0_5x_soft_shadows, tools_eval_refs_gi_ref8_0_5x_cornell_box_scene [INFERRED 0.85]
- **Stress Scene Composition (room, pillars, scattered primitives, emissive lights)** — tools_eval_refs_hwrt_stress_ref_final_cornell_style_room, tools_eval_refs_hwrt_stress_ref_final_pillars, tools_eval_refs_hwrt_stress_ref_final_stress_scene, tools_eval_refs_hwrt_stress_ref_final_emissive_spheres [INFERRED 0.85]
- **Emissive light sources that together light the market scene (string lights, neon signs, lantern discs)** — tools_eval_refs_restir_ref_direct_market_string_lights, tools_eval_refs_restir_ref_direct_market_neon_signs, tools_eval_refs_restir_ref_direct_market_lantern_discs, tools_eval_refs_restir_ref_direct_market_many_light_direct_illumination [INFERRED 0.85]
- **Stress scene composition: Cornell-style room, pillars, dense primitives and emissive spheres** — tools_eval_refs_stress_ref8_final_32_cornell_style_room, tools_eval_refs_stress_ref8_final_32_pillars, tools_eval_refs_stress_ref8_final_32_instanced_primitives, tools_eval_refs_stress_ref8_final_32_emissive_spheres [INFERRED 0.85]
- **Stress scene composition as seen in the albedo reference** — tools_eval_refs_stress_ref_albedo_1_5x_cornell_style_room, tools_eval_refs_stress_ref_albedo_1_5x_primitive_clutter, tools_eval_refs_stress_ref_albedo_1_5x_grey_pillars, tools_eval_refs_stress_ref_albedo_1_5x_black_albedo_spheres, tools_eval_refs_stress_ref_albedo_1_5x_material_palette [INFERRED 0.85]
- **Surfaces and Objects Composing the Upscale Eval Test Scene** — tools_eval_refs_upscale_ref_albedo_red_left_wall, tools_eval_refs_upscale_ref_albedo_green_right_wall, tools_eval_refs_upscale_ref_albedo_light_grey_surfaces, tools_eval_refs_upscale_ref_albedo_yellow_polyhedron, tools_eval_refs_upscale_ref_albedo_blue_sphere, tools_eval_refs_upscale_ref_albedo_black_zero_albedo_spots [INFERRED 0.85]
- **Test scene composition exercised by the upscale reference frame (geometry edges, emissive lights, soft shadows, colored lighting)** — tools_eval_refs_upscale_ref_direct_cornell_box_scene, tools_eval_refs_upscale_ref_direct_scene_objects, tools_eval_refs_upscale_ref_direct_emissive_disc_lights, tools_eval_refs_upscale_ref_direct_two_tone_lighting, tools_eval_refs_upscale_ref_direct_soft_shadows [INFERRED 0.85]

## Communities (176 total, 25 thin omitted)

### Community 0 - "VirtualGeometry"
Cohesion: 0.16
Nodes (8): Group, Params, VirtualGeometry, .clusterCount, .groupCount, .meshCount, .residentMB, .summary

### Community 1 - ".buildWorld"
Cohesion: 0.11
Nodes (17): Open world, GPUEmissiveTriangle, BorrowedLight, BorrowedMesh, BorrowedTree, Instance, .isStatic, .moves (+9 more)

### Community 2 - "Renderer"
Cohesion: 0.05
Nodes (41): 8. Pipelines and resources, LoadOptions, PreparedScene, Renderer, .activeDirectMode, .activeGIMode, .customRT, .dayTime (+33 more)

### Community 3 - "Benchmark"
Cohesion: 0.09
Nodes (10): Benchmark, .current, .framesInConfig, .framesLeftInConfig, .isFinished, .isMeasuring, .progressInConfig, .shouldCapture (+2 more)

### Community 4 - "Foliage"
Cohesion: 0.18
Nodes (11): Card, Carve, Foliage, Graft, Grower, LeafAnchor, LeafRecipe, Level (+3 more)

### Community 5 - "Kernel"
Cohesion: 0.04
Nodes (56): Kernel, accumulate, accumulateColor, atrous, cloudNoise, cloudShadow, composite, crowdPose (+48 more)

### Community 6 - "GLTFLoader"
Cohesion: 0.06
Nodes (43): Accessor, AnyDecodable, Asset, Buffer, BufferView, Document, DocumentExtensions, EmissiveStrength (+35 more)

### Community 7 - "CityStyle"
Cohesion: 0.07
Nodes (26): CityStyle, mixed, modern, office, oldtown, residential, .title, warehouse (+18 more)

### Community 8 - "evalcommon.py"
Cohesion: 0.06
Nodes (7): capture(), flicker(), load(), mean_luminance(), pick_up_refs(), ref(), refs_dir()

### Community 9 - "Rect"
Cohesion: 0.14
Nodes (11): .area, Block, Lamp, Lot, .front, .size, .transform, Rect (+3 more)

### Community 10 - "VoxelLOD"
Cohesion: 0.17
Nodes (3): Entry, VoxelLOD, .megabytes

### Community 11 - "LightSampling.metal"
Cohesion: 0.12
Nodes (32): diskNeighbour(), equalAreaOctDecode(), equalAreaOctEncode(), evalLightSample(), giLightIllum(), lastFramePixel(), LightCandidate, element (+24 more)

### Community 13 - "traceKernel"
Cohesion: 0.10
Nodes (24): 3. Occupancy and registers: the default suspect for big kernels, Light types, groupMask(), penumbraWidth(), cosineSampleHemisphere(), fireflyScale(), luminance(), makeSampler() (+16 more)

### Community 14 - "SettingsPanel"
Cohesion: 0.10
Nodes (7): Action, FlippedView, .isFlipped, SectionHeader, .expanded, SettingsPanel, .fittedSize

### Community 15 - "AABB"
Cohesion: 0.13
Nodes (13): AABB, .area, .centroid, .isEmpty, BinScratch, BLASResult, BVHBuilder, BVHNode (+5 more)

### Community 16 - ".drawFrame"
Cohesion: 0.21
Nodes (10): 1. The frame loop (`Renderer.draw`), The frame: `Renderer.swift`, ComputeStage, CompositeInputs, FramePlan, .prev, FrameSize, .upscaling (+2 more)

### Community 17 - "Bool"
Cohesion: 0.08
Nodes (28): .outputs, DirectLightMode, auto, exact, grouped, restir, .title, Bool (+20 more)

### Community 19 - "Lights.metal"
Cohesion: 0.08
Nodes (51): clipSegment(), groupElement(), isVisible(), isVisibleBlocker(), lightGroup(), lightShadowTarget(), LightSubset, count (+43 more)

### Community 20 - "RenderSettings"
Cohesion: 0.11
Nodes (28): CascadeSettings, CitySettings, ClosedRange, DenoiserSettings, ExtraModel, FogSettings, .windDirection, .windSpeed (+20 more)

### Community 21 - "MTLTexture"
Cohesion: 0.07
Nodes (10): MetalKit, GPURegirParams, DenoiseSignal, DenoiseTargets, FogTargets, .materialBuffers, resourceCreation, RestirGITargets (+2 more)

### Community 22 - "ComputePass"
Cohesion: 0.08
Nodes (11): ComputePass, LBVHCounts, bytes, RTPipelines, .rt, .instanceAS, .instanceDataBuffers, .instanceDescBuffers (+3 more)

### Community 23 - "restirGIInitialKernel"
Cohesion: 0.11
Nodes (32): Indirect light (ReSTIR GI), emptyGIReservoir(), giGeometry(), giLobe(), GIReceiver, depth, n, ng (+24 more)

### Community 24 - ".init"
Cohesion: 0.28
Nodes (6): Scene kinds: `SceneKind` in `Settings.swift`, scale(), translate(), FogVolume, LightPose, Kit

### Community 25 - "Fog.metal"
Cohesion: 0.15
Nodes (26): Volumetric fog, fogAlongRay(), fogFromGrid(), fogHaze(), fogHistory(), fogInjectKernel(), fogInscatter(), fogIntegrateKernel() (+18 more)

### Community 26 - "Upscaler"
Cohesion: 0.12
Nodes (5): Upscaler, .denoising, .hdrOutput, .spatial, View

### Community 27 - "Sky Contact Sheet (11 labelled renders of sky / sun lighting conditions)"
Cohesion: 0.18
Nodes (15): Sky Contact Sheet (11 labelled renders of sky / sun lighting conditions), Panel 00-valley-morning (low sun, dark silhouetted village, warm-lit clouds), Panel 01-valley-forenoon (bright daylight, white cumulus clouds), Panel 02-valley-noon (high sun, short shadows, cloudy sky), Panel 03-valley-afternoon (sun from the left, long shadows, bright cloud bank), Panel 04-valley-evening (dusk, dark ground, orange-lit clouds), Panel 05-valley-clear (cloudless sky gradient, daylight), Panel 06-valley-aerial (high camera over village, fields, road and hills; hazy horizon) (+7 more)

### Community 28 - "SettingsTableTests"
Cohesion: 0.17
Nodes (3): Settings: `SettingsTable.swift`, SettingsEnv, SettingsTableTests

### Community 29 - "Sky.metal"
Cohesion: 0.13
Nodes (28): Sky and clouds, level, atmosphereExtinction(), atmosphereLit(), atmosphereRadiance(), atmosphereTransmittance(), atmosphereTransmittanceMarch(), cloudDensity() (+20 more)

### Community 30 - ".int"
Cohesion: 0.17
Nodes (4): Contents, invalid, unsupported, MappedFile

### Community 31 - "Scene"
Cohesion: 0.13
Nodes (11): GPUMesh, .viewNote, LightMotion, animated, constant, scaleOnly, Scene, .hasFoliage (+3 more)

### Community 32 - "SceneKind"
Cohesion: 0.07
Nodes (28): SceneKind, area, .cameraFromScene, city, cityNight, cornell, crowd, .dayCycle (+20 more)

### Community 33 - "RegirParams"
Cohesion: 0.33
Nodes (4): RegirParams, config, consume, origin

### Community 34 - "Tests"
Cohesion: 0.33
Nodes (6): Proving a refactor changed nothing, Scorers and other tools, Settings, names and lists, Tests, Timings, What could not be run

### Community 36 - "VirtualBLAS"
Cohesion: 0.19
Nodes (8): CutInput, Entry, VirtualBLAS, .instanceCount, .isBusy, .meshCount, .sourceTriangles, .summary

### Community 37 - ".meshes"
Cohesion: 0.17
Nodes (6): Cluster, Group, .isRoot, VGCluster, VirtualGeometryBuilder, VirtualMesh

### Community 39 - "BVHBuild.metal"
Cohesion: 0.19
Nodes (15): 5. Reductions, atomics and threadgroup memory, boxToWorld(), KarrasRange, first, last, split, rtDelta(), rtExpandBits() (+7 more)

### Community 40 - "GPUTypes.swift"
Cohesion: 0.11
Nodes (17): GPUFogParams, .reflectionPassFlags, GPUFogVolume, GPUInstanceData, GPUJoint, .parent, GPUJointMatrix, GPUPoseSlot (+9 more)

### Community 41 - "CityPlan"
Cohesion: 0.16
Nodes (9): Procedural city, CityPlan, Street, View, facade, overview, street, CityTests (+1 more)

### Community 42 - "Uniforms"
Cohesion: 0.09
Nodes (23): Uniforms, bounces, camForward, camPos, camRight, camUp, denoise, flags (+15 more)

### Community 43 - "Notes for M1 / M2 Macs"
Cohesion: 0.21
Nodes (5): Render something: `scripts/render.sh`, 6. Math, Modes, Images, Notes for M1 / M2 Macs

### Community 44 - "GPUProfiler"
Cohesion: 0.08
Nodes (9): FrameEncoder, Metal3Frame, PrimitiveRefit, TLASUpdate, .descriptor, UpscaleInputs, GPUProfiler, .descriptor4 (+1 more)

### Community 45 - "RadianceCascades"
Cohesion: 0.16
Nodes (4): Cascade, RadianceCascades, RCParams, RCPipelines

### Community 46 - "Mesh"
Cohesion: 0.19
Nodes (9): LeafShape, blade, kite, needle, Mesh, .leafTriangles, .triangles, MeshSize (+1 more)

### Community 47 - "same.sh"
Cohesion: 0.83
Nodes (3): run(), same.sh script, usage()

### Community 49 - "simd"
Cohesion: 0.12
Nodes (4): CoreGraphics, Foundation, ImageIO, simd

### Community 50 - "SkinnedCharacter"
Cohesion: 0.14
Nodes (9): Clip, .duration, .loopKeys, Level, .triangleCount, Part, SkinnedCharacter, .triangleCount (+1 more)

### Community 51 - "Capabilities"
Cohesion: 0.28
Nodes (4): Capabilities: `Capabilities.swift`, Capabilities, CapabilitiesTests, .none

### Community 52 - "restirTemporalKernel"
Cohesion: 0.07
Nodes (35): Many lights (ReSTIR DI), quantizeUV(), regirBuildKernel(), RegirCell, base, valid, regirCellTarget(), regirDraw() (+27 more)

### Community 53 - "reflectionKernel"
Cohesion: 0.04
Nodes (72): ggxFromDirection(), lightSpecular(), reflectionHitRadiance(), reflectionKernel(), bindLightSampling(), bindShading(), cloudShadow(), cloudShadowAt() (+64 more)

### Community 54 - "Cornell Box Scene (red left wall, green right wall, white floor/ceiling/back wall)"
Cohesion: 0.21
Nodes (10): Cornell Box Reference Render (HWRT eval, final), Blue Diffuse Sphere (foreground), Cornell Box Scene (red left wall, green right wall, white floor/ceiling/back wall), Emissive Sphere Lights (white near ceiling upper-left, warm near floor lower-left), Floating Rotated Yellow Cube, Hardware Ray Tracing Eval Reference Image (ground truth for image comparison), Cool Blue-Cyan Glow on Right Side (light source hidden behind short box), Short White Box (right side) (+2 more)

### Community 55 - "Intersect.metal"
Cohesion: 0.20
Nodes (21): intersectAny(), intersectClosest(), intersectClosestCost(), intersectDistance(), makeRay(), octDecode(), plantKeep(), Ray (+13 more)

### Community 57 - "Output.metal"
Cohesion: 0.15
Nodes (19): accumulateColorKernel(), accumulateKernel(), acesFilm(), agxFilm(), clipToBox(), compositeKernel(), debugHashColor(), debugHeat() (+11 more)

### Community 58 - "Gallery Scene (steampunk figurines on a stepped display plinth)"
Cohesion: 0.22
Nodes (13): Gallery Scene Reference Render: Close-up Camera (ref-closeup.png), Armored Gunner Figurine (left edge, cropped, arm cannon extended), Clockwork Owl Figurine on Gear Base, Close-up Camera Viewpoint (low, near the figurines, outer models cropped), Eval Reference Image (ground truth for image-quality comparison), Gallery Scene (steampunk figurines on a stepped display plinth), Glossy Reflections of Figurines on Plinth Tops, Mechanical Whale / Submarine Fish Model (+5 more)

### Community 59 - "Pipelines"
Cohesion: 0.25
Nodes (6): Pipelines: `Pipelines.swift`, KernelVariants, .count, Key, Pipelines, .rc

### Community 60 - "SceneBuffers"
Cohesion: 0.09
Nodes (19): buffer, .namedPrimitives, RendererError, .description, missingFunction, InstanceBlock, .hasTree, .held (+11 more)

### Community 61 - ".write"
Cohesion: 0.17
Nodes (4): BlueNoise, .cacheURL, SplitMix64, CacheFile

### Community 63 - "SIMD4"
Cohesion: 0.07
Nodes (20): GPUMaterial, .worldToView, World, .anchorTile, .start, WorldPlace, .anchor, SIMD4 (+12 more)

### Community 64 - "Gallery Reference Render: Overview Camera (ref-overview.png)"
Cohesion: 0.33
Nodes (11): Gallery Reference Render: Overview Camera (ref-overview.png), Bronze Owl Statue (metallic material on round base), Lineup of Textured Character and Statue Models (about ten figures in a row), Neutral Grey Room Enclosure (back wall, ceiling edge, soft indirect lighting), Emissive Sphere Lights (four small white spheres floating above the figures), Eval Reference Image (ground truth for image-quality comparison), Gallery Scene (eval test scene, wide overview view), Global Illumination Result (soft shadows, indirect bounce, glossy reflection, low noise) (+3 more)

### Community 65 - "Stress Scene Reference Render (direct, 1.5x)"
Cohesion: 0.24
Nodes (11): Stress Scene Reference Render (direct, 1.5x), Cornell-Style Room (red left wall, green right wall, neutral floor and ceiling), Direct Mode ("direct" render configuration), Many Small Emissive White Sphere Lights, Eval Reference (Golden) Image for Image-Quality Comparison, Floating Colored Cubes and Spheres (randomly placed and rotated), Low-Frequency Blotchy Shading on Ceiling, Walls and Floor, Many-Light Colored Illumination (magenta, orange and blue pools with soft shadows) (+3 more)

### Community 66 - "Cornell-Box-Style Test Scene (viewed from inside, open front)"
Cohesion: 0.22
Nodes (10): Upscale Eval Reference: Albedo Image (ref-albedo.png), Albedo Auxiliary Buffer (flat unlit base colour, no shading, shadows or noise), Black Zero-Albedo Ellipses (two discs, one on the ceiling/back area and one over the red wall; likely emitters or non-diffuse surfaces), Blue Tessellated Sphere (foreground, lower part hidden by a grey-albedo occluder giving a crescent silhouette), Cornell-Box-Style Test Scene (viewed from inside, open front), Green Right Wall (albedo approx. 0.39, 0.71, 0.43, with a notch from an occluder at its lower-left edge), Light Grey Floor, Ceiling and Back Wall (uniform albedo approx. 0.88, indistinguishable from each other without shading), Red Left Wall (albedo approx. 0.83, 0.27, 0.25) (+2 more)

### Community 67 - "Shaders.metal"
Cohesion: 0.09
Nodes (10): Controls, Denoiser settings, Geometry debug views, Glass, Scene settings, The debug window, The settings panel, glassKernel() (+2 more)

### Community 69 - "RTScene"
Cohesion: 0.09
Nodes (22): RTScene, blas, clusters, cutouts, dynamicRoot, instances, nodeInstance, pad (+14 more)

### Community 70 - "RendererController"
Cohesion: 0.15
Nodes (5): RendererController, .debugActive, .debugInfo, .profilePasses, RendererStatus

### Community 71 - "Flora"
Cohesion: 0.10
Nodes (11): Flora, .geometry, .index, .name, Placed, assembly, flat, Prepared (+3 more)

### Community 72 - "rcTraceMergeKernel"
Cohesion: 0.05
Nodes (33): 3. Parallelism, 4. CPU↔GPU data layout, 5. Preprocessing and caches, 6. CPU tools, CPU (Swift) practices for MetalRenderer, Before declaring done, Checklist: GPU kernels (details: [references/gpu-metal.md](references/gpu-metal.md)), Checklist: offline builders (BVH, simplifier, clusterizer, VG pages, textures) (+25 more)

### Community 73 - "RTBlockInstance"
Cohesion: 0.15
Nodes (13): BVHNode, hi0, hi1, lo0, lo1, RTBlockInstance, mask, pad1 (+5 more)

### Community 74 - "ref-albedo-1.5x.png (stress scene albedo reference render at 1.5x)"
Cohesion: 0.29
Nodes (10): ref-albedo-1.5x.png (stress scene albedo reference render at 1.5x), Albedo view (flat unlit base colour, no shading, shadows or lighting), Black (zero-albedo) spheres scattered through the scene, Cornell-box-style room: red left wall, green right wall, beige floor, grey backdrop, Eval reference (golden) image for the stress scene, Tall light-grey pillars rising from the floor, Fixed albedo palette: red, green, blue, teal, purple, yellow, white, grey, Random primitive clutter: cubes, spheres and hexagonal prisms, floating and resting (+2 more)

### Community 75 - "BuildingAssembler"
Cohesion: 0.23
Nodes (6): BuildingAssembler, Cell, .center, .width, Opening, Ends

### Community 76 - "Double"
Cohesion: 0.07
Nodes (21): Launch, .summary, Double, Terrain, .cell, Block, City, Flora (+13 more)

### Community 77 - "Crowd"
Cohesion: 0.14
Nodes (13): .parts, Crowd, .liveStates, Motion, .isBlend, Part, Slot, State (+5 more)

### Community 78 - "Many-light direct illumination: converged ground-truth direct lighting from a large number of small emitters"
Cohesion: 0.36
Nodes (8): ReSTIR direct-lighting reference render: night market scene (ref-direct-market.png), Capsule figures: red, blue and brown capsule-shaped crowd stand-ins acting as occluders in the street, Round lantern lights: warm emissive discs along the stall fronts, Market stalls: wooden posts, canopies and counters with small coloured box goods, lit from under the awnings, Neon signs: purple, pink and yellow emissive tube shapes on building walls with glow, Night market street scene (stall-lined alley between buildings under a dark sky), ReSTIR eval reference image (ground truth the eval tool compares renders against), String lights: hundreds of small multicoloured emissive bulbs strung across the street

### Community 79 - "EnvVariable"
Cohesion: 0.09
Nodes (22): EnvVariable, api, denoise, direct, fog, fogSet, foliage, gi (+14 more)

### Community 80 - "atrousKernel"
Cohesion: 0.29
Nodes (7): atrousKernel(), depthGradient(), geometryWeights(), readNoisy(), shadowFilterKernel(), shadowTemporalKernel(), temporalKernel()

### Community 81 - "FogParams"
Cohesion: 0.15
Nodes (13): FogParams, albedo, counts, grid, medium, noise, volumes, wind (+5 more)

### Community 82 - ".add"
Cohesion: 0.09
Nodes (20): Building, .triangleCount, BuildingGenerator, BuildingSpec, Slot, accent, blind, dark (+12 more)

### Community 83 - "GI eval reference image ref8 at 0.5x (Cornell-box style render)"
Cohesion: 0.43
Nodes (8): GI eval reference image ref8 at 0.5x (Cornell-box style render), Indirect color bleeding (red and green wall tint on floor, white boxes and back wall), Cornell box test scene (red left wall, green right wall, white floor/ceiling/back wall), Emissive white sphere lights (one near ceiling upper-left, one near floor lower-left), Global illumination reference (converged, noise-free ground truth for GI evaluation), 0.5x render scale variant (640x400 reference), Scene objects: tall white box, short white box, floating rotated yellow cube, blue sphere, white sphere in foreground, Soft shadows and contact occlusion under boxes and spheres

### Community 84 - "GI reference render ref8 at 1.5x (Cornell-box scene)"
Cohesion: 0.36
Nodes (8): GI reference render ref8 at 1.5x (Cornell-box scene), Diffuse color bleeding (red and green wall bounce tinting white surfaces), Cornell-box test scene (red left wall, green right wall, white floor/ceiling/back wall), Two white emissive sphere lights (upper left near ceiling, lower left near floor), 1.5x variant of reference 8 (exposure/intensity multiplier per filename), Global illumination ground-truth reference (converged, noise-free), Scene objects: tall white box, floating tilted yellow cube, short white box, blue sphere, white sphere in foreground, Soft area-light shadows and contact occlusion

### Community 85 - "Stress Test Scene: hundreds of scattered coloured cubes and spheres in a pillared room"
Cohesion: 0.39
Nodes (7): Stress Scene Reference Render ref8-final-32 (640x400), Cornell-Style Room: red left wall, green right wall, pale floor and ceiling, Small Bright White Emissive Spheres (scattered light sources), Eval Reference Image (ground truth for image-quality comparison, stress set), Dense Field of Randomly Coloured, Randomly Rotated Cubes and Spheres (floating and resting), White Square Pillars (floor-to-ceiling occluders), Stress Test Scene: hundreds of scattered coloured cubes and spheres in a pillared room

### Community 86 - "SceneShading"
Cohesion: 0.13
Nodes (13): MaterialTexture, t, SceneShading, cloudShadow, emissive, feedback, materials, minLod (+5 more)

### Community 87 - "PlantWind"
Cohesion: 0.24
Nodes (12): boneAngle(), coverLean(), PlantWind, angle, axis, gust, phase, time (+4 more)

### Community 88 - "OffscreenSurface"
Cohesion: 0.15
Nodes (9): Offscreen rendering in MetalRenderer, Recipes, Rules, What headless changes, and what it doesn't, Encoding for both APIs: `ComputePass.swift`, `Metal4Backend.swift`, FrameOutput, Headless, OffscreenSurface (+1 more)

### Community 89 - "SIMD3"
Cohesion: 0.18
Nodes (8): Faces, MeshBuilder, .bounds, .geometry, .isEmpty, .triangleCount, SIMD3, .envText

### Community 90 - "Float"
Cohesion: 0.08
Nodes (18): .windFrame, Assembly, Bone, Light, .isMesh, LightKind, .isSun, mesh (+10 more)

### Community 91 - "EmissiveTriangle"
Cohesion: 0.18
Nodes (10): EmissiveTriangle, e1, e2, uv12, v0, Light, axis, color (+2 more)

### Community 93 - "SkyParams"
Cohesion: 0.15
Nodes (13): SkyParams, cloudLayer, cloudShape, flags, glow, glowTop, ground, place (+5 more)

### Community 94 - "Footprint"
Cohesion: 0.23
Nodes (5): BuildingTier, .top, Footprint, .cover, .loops

### Community 95 - "Stress Scene Reference Render (hwrt, final)"
Cohesion: 0.43
Nodes (6): Stress Scene Reference Render (hwrt, final), Cornell-style Room (red left wall, green right wall, white floor and ceiling), Many Small Emissive White Spheres (area lights), Hardware Ray Tracing Eval Reference Image, White Floor-to-Ceiling Pillars (occluders), Stress Scene: hundreds of scattered coloured cubes and spheres

### Community 96 - "ref-direct-32.png (ReSTIR eval reference render, direct lighting)"
Cohesion: 0.38
Nodes (7): ref-direct-32.png (ReSTIR eval reference render, direct lighting), Many-object test scene: pillared room filled with scattered colored spheres and cubes, Many small emissive point-like lights (bright white spots, colored local illumination), Cornell-box-style red left wall and green right wall, ReSTIR direct-lighting reference image (ground truth for eval comparison), Smooth, low-noise direct illumination with soft shadows on the floor (converged look), Variant '32' in filename (likely sample count or light-count setting)

### Community 97 - "Many-light test scene (hundreds of small emitters in a room of scattered primitives)"
Cohesion: 0.38
Nodes (7): ReSTIR eval reference image: direct lighting, 4096 samples (ref-direct-4096.png), Cornell-box-style room: red left wall, green right wall, pale floor and ceiling, back columns, Converged direct-lighting ground truth (4096 spp reference for ReSTIR evaluation), Localised light pools and soft shading from nearby emitters (direct illumination only), Many-light test scene (hundreds of small emitters in a room of scattered primitives), Randomly placed coloured cubes and spheres (floating and resting on the floor), Small white emissive lights scattered through the volume of the room

### Community 98 - "Shadow Eval Reference Image: Direct Lighting (ref-direct.png)"
Cohesion: 0.52
Nodes (6): Shadow Eval Reference Image: Direct Lighting (ref-direct.png), Multi-Colored Light Contributions (warm orange glow on red wall, cool blue tint on back wall, cyan highlight on green wall), Cornell-Box-Style Test Scene (red left wall, green right wall, neutral back wall/floor/ceiling), Visible Emissive Sphere Lights (white, upper-left ceiling area and lower-left near red wall), Shadow Occluders (tall white box, floating rotated yellow cube, tan box, dark blue sphere, beige sphere), Soft Area-Light Shadows with Penumbra (overlapping multi-light shadows on back wall and floor)

### Community 99 - "Stress scene reference render: direct lighting, 32 (ref-direct-32.png)"
Cohesion: 0.48
Nodes (7): Stress scene reference render: direct lighting, 32 (ref-direct-32.png), Cornell-box-style room: red left wall, green right wall, pale ceiling and floor, square pillars, Direct lighting reference image (ground truth for eval comparison), Many small bright emissive spheres acting as point-like lights with coloured local illumination, 32 in file name (likely samples per pixel or light samples for the reference), Soft shadows and smooth shading under scattered objects, low visible noise, Stress test scene: room filled with hundreds of scattered coloured spheres and cubes

### Community 100 - "Upscale eval reference image: ref-direct (1920x1200 render of Cornell-box test scene)"
Cohesion: 0.57
Nodes (7): Upscale eval reference image: ref-direct (1920x1200 render of Cornell-box test scene), Cornell-box style test scene (red left wall, green right wall, neutral floor/ceiling/back wall), Visible white emissive disc lights (one near ceiling, one near floor at left wall), Scene objects: tall white box, floating tilted yellow cube, tan box, dark blue sphere, pale sphere in foreground, Soft penumbra shadows (blurred cube shadow on back wall and ceiling, sharp contact shadows near boxes and spheres), Two-tone lighting: warm light on the left side, cool blue light on the right/back wall, Upscale evaluation reference baseline ('direct' variant: noise-free golden frame to compare upscaler output against)

### Community 101 - "RTPart"
Cohesion: 0.17
Nodes (12): RTPart, blasRoot, bough, boughAxis, firstLeaf, leafCount, limb, limbAxis (+4 more)

### Community 102 - "BuildingStyle"
Cohesion: 0.11
Nodes (17): Balustrade, bars, glass, solid, BuildingStyle, PlanShape, courtyard, l (+9 more)

### Community 103 - "GI eval reference image ref8 (indirect, 0.5x)"
Cohesion: 0.47
Nodes (5): GI eval reference image ref8 (indirect, 0.5x), Black disc regions on left wall and ceiling edge, Cornell-box style GI test scene (red/green walls, boxes, spheres), GI eval reference set (Tools/eval/refs/gi), 0.5x indirect variant (half indirect intensity or half-resolution GI)

### Community 104 - "ReSTIR eval reference image: direct lighting, 1024 (ref-direct-1024.png)"
Cohesion: 0.47
Nodes (5): ReSTIR eval reference image: direct lighting, 1024 (ref-direct-1024.png), Many-light test scene (hall of scattered cubes and spheres with hundreds of small emissive lights), ReSTIR direct-lighting quality evaluation, Scene geometry: randomly placed colored cubes and spheres, white pillars, red left wall, green right wall, diffuse floor and ceiling, Small white emissive sphere lights scattered through the volume

### Community 105 - "ReSTIR eval reference image: direct lighting, 128 (ref-direct-128.png)"
Cohesion: 0.53
Nodes (4): ReSTIR eval reference image: direct lighting, 128 (ref-direct-128.png), Cornell-box-style room: red left wall, green right wall, grey pillars, pale floor and ceiling, Small white emissive sphere lights scattered through the scene (dozens of point-like emitters), Many-light test scene: pillared room filled with scattered coloured cubes and spheres

### Community 106 - "ReSTIR eval reference image: indirect lighting, market scene (ref-indirect-market.png)"
Cohesion: 0.53
Nodes (6): ReSTIR eval reference image: indirect lighting, market scene (ref-indirect-market.png), Coloured pillars (red, blue, green) as colour-bleeding probes for bounce light, Indirect-only illumination (dim, warm bounce light with no visible direct light or emitters), Market street test scene (two rows of facades with window cutouts, stall poles, coloured pillars down a central alley, black sky), Residual Monte Carlo noise (bright speckle/fireflies across facades and ground in the reference), ReSTIR indirect (GI) ground-truth reference for image-quality evaluation

### Community 107 - "ReSTIR eval reference image: scattering, market scene (ref-scattering-market.png)"
Cohesion: 0.53
Nodes (5): ReSTIR eval reference image: scattering, market scene (ref-scattering-market.png), Ground-truth reference render for image-quality evaluation (640x400), Many small emissive lights (string-light points and round lantern-like spots), Market scene at night: street corridor flanked by railings and stalls, overhead cables with string lights, dark foreground silhouettes, ReSTIR reference image set (Tools/eval/refs/restir)

### Community 108 - "Stress scene reference render: ref8-indirect-32 (indirect lighting eval reference image)"
Cohesion: 0.53
Nodes (5): Stress scene reference render: ref8-indirect-32 (indirect lighting eval reference image), Cornell-box-style room: red left wall, green right wall, pale floor and ceiling, white pillars, Eval reference image: ground-truth frame the eval tool compares renderer output against, Soft contact shadows and occlusion under objects in the reference frame, Stress scene: hundreds of randomly placed, randomly coloured cubes and spheres filling a room

### Community 109 - "Stress test scene (pillared room filled with hundreds of floating cubes and spheres)"
Cohesion: 0.47
Nodes (6): Stress scene reference render: direct lighting, 128 (ref-direct-128.png), Randomly coloured diffuse cubes and spheres with soft shadows, Cornell-style enclosure: red left wall, green right wall, grey pillars, pale floor and ceiling, Direct-lighting ground-truth reference image for the eval tool, Many small white emissive sphere lights scattered through the scene, Stress test scene (pillared room filled with hundreds of floating cubes and spheres)

### Community 110 - "ab.sh"
Cohesion: 0.70
Nodes (4): check_bin(), run(), ab.sh script, usage()

### Community 111 - "DebugPanel"
Cohesion: 0.08
Nodes (13): DebugInfo, DebugPanel, .wasVisible, FlippedView, .isFlipped, FrameGraphView, Section, VirtualGeometry (+5 more)

### Community 112 - "FBXError"
Cohesion: 0.14
Nodes (10): FBXError, .description, BlobReader, BlobWriter, CharacterLibrary, .directory, concurrently(), Mapping (+2 more)

### Community 114 - "SkyImage"
Cohesion: 0.25
Nodes (4): Atmosphere, LoadError, unreadable, SkyImage

### Community 115 - "InstanceData"
Cohesion: 0.22
Nodes (8): InstanceData, materialIndex, meshIndex, normalMatrix, pad0, pad1, prevTransform, transform

### Community 116 - "FoliageTextures"
Cohesion: 0.15
Nodes (10): CardSheet, FoliageTextures, Image, Kind, birchBark, grass, leaf, .name (+2 more)

### Community 117 - "SurfaceKind"
Cohesion: 0.15
Nodes (12): SurfaceKind, asphalt, brick, concrete, .hasRoughness, metalpanel, paving, plaster (+4 more)

### Community 118 - "Metal4Frame"
Cohesion: 0.05
Nodes (8): FrameTimes, Buffer, mappings, metal3, metal4, FeedbackCollector, Metal4Frame, .declarationScope

### Community 121 - "Camera"
Cohesion: 0.25
Nodes (6): Darwin, Camera, .forward, .right, .up, rotate()

### Community 122 - "VirtualGeometry.metal"
Cohesion: 0.38
Nodes (7): vgCutKernel(), vgFinishKernel(), vgFitKernel(), vgHierarchyKernel(), vgPadKernel(), vgResetKernel(), vgSameInstance()

### Community 123 - "LayerSurface"
Cohesion: 0.20
Nodes (6): LayerSurface, .backingScale, .isVisible, .outputSize, .pointSize, .title

### Community 126 - "FoliageVoxels"
Cohesion: 0.15
Nodes (8): FoliageVoxels, Grid, Piece, Plant, BoxData, VoxelGrids, .buffers, .megabytes

### Community 127 - "FBXFile"
Cohesion: 0.16
Nodes (11): Children, Connection, FBXFile, .topLevel, Int64, Node, CharacterImporter, Skeleton (+3 more)

### Community 128 - "Metal"
Cohesion: 0.21
Nodes (5): AppKit, Metal, MetalFX, QuartzCore, UniformTypeIdentifiers

### Community 129 - "Species"
Cohesion: 0.12
Nodes (19): Age, mature, sapling, young, Bone, Part, Plant, .height (+11 more)

### Community 130 - "Material"
Cohesion: 0.33
Nodes (5): Material, albedo, emission, params, textures

### Community 131 - "Types.metal"
Cohesion: 0.12
Nodes (16): InstanceBlockRef, records, instanceRecord(), MeshData, block, cutout, firstIndex, indexCount (+8 more)

### Community 132 - "Phyllotaxis"
Cohesion: 0.50
Nodes (4): Phyllotaxis, distichous, spiral, whorled

### Community 133 - "CustomRayTracer"
Cohesion: 0.11
Nodes (14): CustomRayTracer, .buffers, .dynamicNodeBase, .dynamicRoot, .virtualNodeBase, RefitParams, RTInstance, RTPart (+6 more)

### Community 134 - "Crowd.metal"
Cohesion: 0.21
Nodes (12): CrowdJoint, inverseBindRotation, inverseBindTranslation, local, crowdRotation(), JointMatrix, row0, row1 (+4 more)

### Community 136 - "Measuring MetalRenderer"
Cohesion: 0.33
Nodes (6): A/B protocol, Kernel variants, Launch time, Measuring MetalRenderer, Narrowing and overriding, Reading the table

### Community 137 - "Int32"
Cohesion: 0.28
Nodes (6): Compression, FBXArrayElement, Float, Int32, LocalIds, MeshClusterizer

### Community 138 - "crowdPoseKernel"
Cohesion: 0.33
Nodes (5): Animated characters, crowdPoseKernel(), crowdRefitKernel(), crowdRoot(), crowdSkinKernel()

### Community 139 - "Int"
Cohesion: 0.09
Nodes (10): lit, GPULight, meshLights, .namedBlocks, .namedInstanceBlocks, CityLight, .data, made (+2 more)

### Community 140 - ".sources"
Cohesion: 0.19
Nodes (3): Maps, ProceduralTextures, ProceduralTextureTests

### Community 141 - "TextureStreamer"
Cohesion: 0.07
Nodes (13): Entry, Level, SparseMapping, TextureStreamer, .details, .placement, .residentLevels, .summary (+5 more)

### Community 143 - "Map"
Cohesion: 0.18
Nodes (6): Map, Related tests only, Rules, Run them: `scripts/related.sh`, When the map misses, MaterialTextures

### Community 144 - "PoseSlot"
Cohesion: 0.22
Nodes (9): PoseSlot, blend, pad, rootA, rootB, rotationsA, rotationsB, timeA (+1 more)

### Community 146 - "RTInstance"
Cohesion: 0.25
Nodes (8): RTInstance, blasRoot, mask, pad0, pad1, row0, row1, row2

### Community 148 - "VGInstance"
Cohesion: 0.20
Nodes (8): VGInstance, clusterBase, clusterCount, hi, instance, lo, workBase, vgProjected()

### Community 149 - "CrowdPoseParams"
Cohesion: 0.22
Nodes (9): CrowdPoseParams, firstSlot, jointBase, jointCount, pad0, pad1, pad2, paletteStride (+1 more)

### Community 150 - "CrowdSkinParams"
Cohesion: 0.22
Nodes (9): CrowdSkinParams, bindBase, currentBase, firstSlot, paletteStride, previousBase, skinBase, slotCount (+1 more)

### Community 151 - "SectionFile"
Cohesion: 0.08
Nodes (12): 2. Hot loops (BVH, MeshSimplifier, MeshClusterizer, VirtualGeometryBuilder, BlueNoise, FogNoise), CryptoKit, Generated plants, Section, Section, GeneratedCache, Hasher, SectionFile (+4 more)

### Community 152 - "VGParams"
Cohesion: 0.20
Nodes (10): VGParams, camPos, capacity, frame, instanceCount, nodeBase, pad, requestCapacity (+2 more)

### Community 153 - "ShadingPoint"
Cohesion: 0.22
Nodes (9): ShadingPoint, albedo, f0, n, ng, p, roughness, specular (+1 more)

### Community 154 - "GPU (Metal / MSL) practices for MetalRenderer"
Cohesion: 0.20
Nodes (10): 10. GPU tools, 1. Frame structure and submission, 2. Memory bandwidth: the default suspect for screen-space passes, 4. Divergence and memory access patterns, 7. Acceleration structures and ray tracing, 9. Shader helpers: use them, don't copy, GPU (Metal / MSL) practices for MetalRenderer, StreamPick (+2 more)

### Community 155 - "Custom"
Cohesion: 0.22
Nodes (9): Custom, clearModels, denoiserCaption, fogAlbedo, lightRays, scene, skyImage, skyMode (+1 more)

### Community 156 - "VGCluster"
Cohesion: 0.22
Nodes (9): VGCluster, childGroup, group, hi, lo, pageOffset, parentSphere, selfSphere (+1 more)

### Community 157 - "RTVoxels"
Cohesion: 0.29
Nodes (5): RTVoxels, dims, lo, offsets, voxelDims()

### Community 158 - "CrowdRefitParams"
Cohesion: 0.40
Nodes (5): CrowdRefitParams, nodeBase, nodeCount, pad, tag

### Community 159 - "uint"
Cohesion: 0.25
Nodes (6): crowdLeaf(), SkinVertex, joints, w0, w1, w2

### Community 160 - "Shape"
Cohesion: 0.29
Nodes (6): Shape, courtyard, l, rect, t, u

### Community 161 - "Hit"
Cohesion: 0.22
Nodes (8): Hit, barycentrics, cluster, distance, hit, instance, part, primitive

### Community 163 - "related.sh"
Cohesion: 0.83
Nodes (3): add(), related.sh script, usage()

### Community 164 - "How a frame works"
Cohesion: 0.25
Nodes (6): Benchmark mode, Build and run, Hardware ray tracing, MetalFX's denoiser and Metal 4, How a frame works, MetalRenderer, Where to go next

### Community 167 - "VGBlas"
Cohesion: 0.11
Nodes (18): rtCutout(), VGBlas, attrs, nodes, pad, triangles, tris, VGClusterView (+10 more)

### Community 170 - "LightTable"
Cohesion: 0.53
Nodes (4): GPULightTableEntry, GPUTriangleInfo, LightTable, .byteCount

### Community 171 - "Edge"
Cohesion: 0.50
Nodes (4): Edge, open, party, street

### Community 172 - "Builder"
Cohesion: 0.40
Nodes (4): Builder, hybrid, sah, spliced

### Community 173 - "Crown"
Cohesion: 0.29
Nodes (6): Crown, conical, cylindrical, flame, hemispherical, spherical

## Ambiguous Edges - Review These
- `Two-tone lighting: warm light on the left side, cool blue light on the right/back wall` → `Upscale evaluation reference baseline ('direct' variant: noise-free golden frame to compare upscaler output against)`  [AMBIGUOUS]
  Tools/eval/refs/upscale/ref-direct.png · relation: conceptually_related_to
- `GI eval reference image ref8 (indirect, 0.5x)` → `0.5x indirect variant (half indirect intensity or half-resolution GI)`  [AMBIGUOUS]
  Tools/eval/refs/gi/ref8-indirect-0.5x.png · relation: conceptually_related_to
- `Black disc regions on left wall and ceiling edge` → `Indirect lighting with color bleeding from red and green walls`  [AMBIGUOUS]
  Tools/eval/refs/gi/ref8-indirect-0.5x.png · relation: conceptually_related_to
- `Cornell Box Scene (red left wall, green right wall, white floor/ceiling/back wall)` → `Cool Blue-Cyan Glow on Right Side (light source hidden behind short box)`  [AMBIGUOUS]
  Tools/eval/refs/hwrt/cornell-ref-final.png · relation: references
- `Cool Blue-Cyan Glow on Right Side (light source hidden behind short box)` → `Short White Box (right side)`  [AMBIGUOUS]
  Tools/eval/refs/hwrt/cornell-ref-final.png · relation: conceptually_related_to
- `Direct Mode ("direct" render configuration)` → `Many-Light Colored Illumination (magenta, orange and blue pools with soft shadows)`  [AMBIGUOUS]
  Tools/eval/refs/stress/ref-direct-1.5x.png · relation: conceptually_related_to
- `Low-Frequency Blotchy Shading on Ceiling, Walls and Floor` → `Many-Light Colored Illumination (magenta, orange and blue pools with soft shadows)`  [AMBIGUOUS]
  Tools/eval/refs/stress/ref-direct-1.5x.png · relation: conceptually_related_to
- `Black Zero-Albedo Ellipses (two discs, one on the ceiling/back area and one over the red wall; likely emitters or non-diffuse surfaces)` → `Cornell-Box-Style Test Scene (viewed from inside, open front)`  [AMBIGUOUS]
  Tools/eval/refs/upscale/ref-albedo.png · relation: conceptually_related_to
- `Albedo view (flat unlit base colour, no shading, shadows or lighting)` → `Black (zero-albedo) spheres scattered through the scene`  [AMBIGUOUS]
  Tools/eval/refs/stress/ref-albedo-1.5x.png · relation: conceptually_related_to
- `Variant '32' in filename (likely sample count or light-count setting)` → `ref-direct-32.png (ReSTIR eval reference render, direct lighting)`  [AMBIGUOUS]
  Tools/eval/refs/restir/ref-direct-32.png · relation: references
- `Direct lighting reference image (ground truth for eval comparison)` → `32 in file name (likely samples per pixel or light samples for the reference)`  [AMBIGUOUS]
  Tools/eval/refs/stress/ref-direct-32.png · relation: conceptually_related_to
- `32 in file name (likely samples per pixel or light samples for the reference)` → `Stress scene reference render: direct lighting, 32 (ref-direct-32.png)`  [AMBIGUOUS]
  Tools/eval/refs/stress/ref-direct-32.png · relation: references

## Knowledge Gaps
- **820 isolated node(s):** `PackageDescription`, `.isEmpty`, `.centroid`, `.area`, `built` (+815 more)
  These have ≤1 connection - possible missing edges or undocumented components. (Counts symbols only; 1181 node(s) total have ≤1 connection when file, concept and rationale nodes are included.)
- **25 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **What is the exact relationship between `Two-tone lighting: warm light on the left side, cool blue light on the right/back wall` and `Upscale evaluation reference baseline ('direct' variant: noise-free golden frame to compare upscaler output against)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `GI eval reference image ref8 (indirect, 0.5x)` and `0.5x indirect variant (half indirect intensity or half-resolution GI)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `Black disc regions on left wall and ceiling edge` and `Indirect lighting with color bleeding from red and green walls`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `Cornell Box Scene (red left wall, green right wall, white floor/ceiling/back wall)` and `Cool Blue-Cyan Glow on Right Side (light source hidden behind short box)`?**
  _Edge tagged AMBIGUOUS (relation: references) - confidence is low._
- **What is the exact relationship between `Cool Blue-Cyan Glow on Right Side (light source hidden behind short box)` and `Short White Box (right side)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `Direct Mode ("direct" render configuration)` and `Many-Light Colored Illumination (magenta, orange and blue pools with soft shadows)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._
- **What is the exact relationship between `Low-Frequency Blotchy Shading on Ceiling, Walls and Floor` and `Many-Light Colored Illumination (magenta, orange and blue pools with soft shadows)`?**
  _Edge tagged AMBIGUOUS (relation: conceptually_related_to) - confidence is low._