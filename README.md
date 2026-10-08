# MetalRenderer

A minimal real-time ray tracer for macOS and Metal, with dynamic lights and global illumination.
It's built for Apple Silicon and tuned for an M1 Max.

* **Dynamic scenes:** objects and lights move every frame. Pick a scene in the settings panel:
  * a small Cornell-style room;
  * a **stress test** building (a warehouse, a factory floor, a parking garage and an office) with up to 2000 props and 16384 lights (see below);
  * a **Night market** street lit by thousands of festoon bulbs, lanterns, windows and neon signs (see "Many lights" below);
  * the glTF **Gallery**;
  * a **Showcase** for each glTF model: the model alone on a set of its own, with volumetric beams, mist, drifting particles, bloom and depth of field (see "Showcase" below);
  * six light demos (see "Light types" below);
  * a **Misty hall** for the volumetric fog (see "Volumetric fog" below);
  * an **Open valley** for the sky and clouds (see "Sky and clouds" below);
  * a **Forest** of generated trees, bushes, ferns and grass on rolling ground (see "Generated plants" below);
  * a **Crowd**: a square with thousands of animated characters, skinned on the GPU (see "Animated characters" below);
  * a generated **City**, by day and at night: blocks of procedural buildings with glass windows and rooms behind them (see "Procedural city" below);
  * an **Open world**: hills, forest and cities without end, made around the camera as it moves, under a day that goes through dusk into a moonlit night (see "Open world" below).
* **Glass:** window panes the camera sees through and sees reflections in, and that light passes (see "Glass" below).
* **Light types:** sphere (point) lights, **spot** lights, a **sun** with a sky colour, **rect** area lights and **tube** lights.
  * Every type has soft ray-traced shadows, GGX highlights, the shadow denoiser and every GI method.
  * The scene's shaders are specialised for the light types it uses, so a scene with only sphere lights runs the same code as before.
* **Emissive meshes are lights:** any glowing surface (a neon sign, a screen, a glTF emissive texture) is sampled for direct light with shadow rays, one triangle at a time.
* **glTF lights:** `KHR_lights_punctual` point, spot and directional lights load with their models.
* **SDF shapes:** geometry given by signed distance fields, sphere-traced in the boxes Metal's traversal hands to the shader.
  * Primitives (sphere, rounded box, torus, capsule, cylinder, cone), cut, intersected and smoothly blended into one another, a material per node.
  * Meshes baked into distance grids that can be used like any primitive.
  * Glowing shapes are lights, sampled like emissive meshes.
* **Sky and clouds:** a physically based atmosphere, or an HDR environment image, with the sun.
  * The atmosphere has Rayleigh, Mie and ozone, with multiple scattering. It gives blue skies, bright horizons and red sunsets, and the sun light's colour follows it.
  * An image's sun is found and cut out, and the sun light takes its place.
  * In front of either sky there are volumetric clouds, and their shadows drift over the scene.
  * The sky lights everything: camera view, GI, reflections, fog.
  * Cost: 0.2–1 ms per frame, whatever the resolution.
* **Generated plants:** oaks, birches, conifers, dead trees, bushes, ferns and grass, grown from a seed in about 2 ms.
  * A tree is an **assembly**: a trunk, limbs and a few hundred placed copies of six shared boughs, traced through Metal's multi-level instancing. The forest's 2,500 trees are 29 plants of 3,500 parts.
  * **Wind** turns every limb and bough about its bone, leans each plant on its own, and leans the grass: each assembly has a posed variant per phase of the wind, refitted every frame.
  * A **season** setting turns the leaves and drops them; leaves let light through. Far plants can be traced as **voxels** (off by default: slower wherever it was measured).
* **Volumetric fog and light:** height fog with drifting noise, plus soft-edged local fog volumes (ground mist, a stage haze, a glow around a lamp).
  * Every light type scatters in it, with ray-traced shadows, so sunlight falls in shafts through windows and spot beams are visible.
  * It is computed in a camera-aligned voxel grid ("froxels"), 8×8 traced pixels by 64 depth slices.
  * Reflections are fogged too.
  * Cost: 0.2–1 ms at 640×400.
  * It matches a per-pixel ray-marched reference within 1.5% (see below).
* **Ray tracing with Metal's acceleration structures:** every ray (camera, shadow, GI, reflection, fog) is a query of Metal's intersector, in software on M1 and M2 and in hardware on M3 and later. A GPU without Metal ray tracing is refused at launch.
  * Each mesh gets a bottom-level structure, built with the scene for fast intersection and compacted; every instance is in one top-level structure.
  * A scene in which nothing moves (`Scene.isStill`: no moving instance, no virtual geometry, no plant in the wind) has its top-level structure built once, with the scene, for tracing. In one that moves it is refitted every frame and rebuilt every 16 frames, or as soon as an instance names another structure (a new virtual-geometry cut, a plant's other variant).
  * The kernels get the scene at buffer 1 as a `TraceScene` argument buffer, one per frame slot (`TraceScene.swift`): the top-level structure by resource ID, virtual geometry's tables, the plants' parts and the wind, the leaf cards' alpha layers with the mesh arrays their test reads, and the `RT_STATS` counters.
  * What the traversal can't decide alone it hands to the shader, through intersection queries: far plants' voxel boxes, SDF shapes, virtual geometry's cluster boxes (in its clusters mode) and the leaf cards' alpha test. In software ray tracing each hand-over is dear.
  * Until October 2026 the shaders could also walk this project's own two-level BVH, the "custom tracer" (the default then: 19–24% faster than Metal's intersector in the stress test on an M1 Max, slower than its hardware traversal on an M4 Max). It was removed (see "Removing the custom tracer" below); numbers in this file measured on it say so.
* **glTF models:** `.glb` and `.gltf` files load with their node hierarchy and metallic-roughness materials.
  * The **Gallery** scene shows every model in `Assets/` on plinths, two of them on turntables, under 8 moving lights.
  * File > Open… (⌘O) or dropping files on the window adds models to any scene.
  * Textures supported: base colour, metallic-roughness, normal and emissive (normal maps use tangents derived per triangle from the UVs).
  * Scenes load in the background while the old one keeps rendering.
* **Virtual geometry (Nanite-style, on by default):** meshes of 65k+ triangles become level-of-detail DAGs of 128-triangle clusters.
  * Everything is this project's own code: clustering, quadric simplification with locked group borders, seam- and border-aware collapses, and the DAG.
  * Each model is built once (about 7 s per 2M triangles) and cached in `Assets/.metalrenderer-cache/`.
  * Every few frames a background thread picks Nanite's cut for each instance: every cluster whose simplification error projects to under 1 traced pixel and whose parent's doesn't.
    * The cut is computed in parallel, tests each group once before its clusters, and skips instances it can prove unchanged. Those are instances that haven't moved, with the camera closer to where it was than any test is to flipping, so a still camera costs nothing.
  * Each instance whose cut changed gets a fresh BLAS over exactly those triangles (`VirtualBLAS.swift`): they are read from the memory-mapped cache, so the OS streams pages from disk (prefetched with `madvise` first), gathered into a buffer, and Metal builds its structure over them on a command queue of its own, so frames never wait behind a build. The virtual instance's descriptor names the new BLAS, and the top-level structure is rebuilt over it (`VirtualTracing.swift`). Triangle buffers are recycled.
  * Rays see one tight structure per model.
  * The gallery's 17.9M triangles trace as a cut of about 0.4M triangles in about 107 MB of structures and triangles, instead of ~1.5 GB (see below).
  * Debug views (key 9) show triangles, clusters, groups, DAG levels, projected triangle size and traversal cost. Freeze LOD (L) keeps the cut chosen for where the camera was, so you can fly up and inspect it.
* **Physically based materials:** GGX specular with Smith visibility and Schlick Fresnel for glTF materials and the city's glass, metal and stone; the other generated scenes stay diffuse and unchanged.
  * Direct specular is exact per light (representative-point sphere lights), multiplied by the shadow denoiser's visibility in the composite.
  * Indirect specular comes from a reflection pass: one GGX visible-normal ray per pixel, divided by an analytic specular albedo and denoised.
  * References follow full paths.
* **Texture streaming:** textures are cached at full resolution with full mip chains and live in a sparse heap (budget 1 GB, or as much as all the scene's textures could map, if that is less: the heap counts in full against the app's memory whatever is mapped of it).
  * Primary hits count, per texture, the mip levels they need.
  * The streamer maps and uploads the finest level 1.5% of the samples need and unmaps levels nobody needed lately.
  * The gallery's 2.6 GB of 4K textures need 14 MB from the overview and 46–65 MB close up.
* **Direct light:** ray-traced soft shadows. With up to 4 lights, each light gets one shadow ray per pixel. With more, lights are split into 4 colour groups, and each pixel picks one light per group, weighted by how much light it would get from it unshadowed, then traces one shadow ray to it. That's 4 rays per pixel whatever the light count, but picking still weighs every light.
* **ReSTIR DI for many lights (default above 256 lights):** each pixel draws a few candidate lights from a world-space light grid (ReGIR: reservoirs per cell, rebuilt on the GPU every frame from the current lights, so moving and flickering lights cost nothing) and from a power-weighted alias table in O(1), keeps one by resampling, and reuses last frame's and its neighbours' picks. GI's bounces, the reflections and the fog draw their light samples from the same grid. The cost depends on the resolution, not the light count: 16384 lights cost 17 ms where 4096 lights cost 53 ms with the grouped picker (see "Many lights" below).
* **Global illumination, four methods** (switch with **M** or in the settings panel):
  * **Radiance cascades (default):** probes on a screen grid trace world-space rays over distance intervals that grow 4× per cascade. The cascades are merged top-down, giving each probe its incoming light without noise.
  * **Path traced:** a 1-sample-per-pixel diffuse path is traced for 1 to 8 bounces. Each bounce samples one light directly (next-event estimation), picked in proportion to its unshadowed light there, and picks up sky light. The result is denoised.
  * **ReSTIR GI:** the same paths, but each path's first bounce is kept as a reservoir sample and resampled from frame to frame (optionally also from neighbouring pixels, unbiased). Its paths' last hits add last frame's indirect light (multi-bounce). It is the most accurate method: 42.2 dB in the Cornell room and 36.4 dB in the stress hall, against 36.1 and 25.5 dB for radiance cascades, for 2–3× their cost (see "Indirect light (ReSTIR GI)" below).
  * **Lumen (Unreal Engine 5-style, software):** screen probes trace the screen first, then each mesh's signed distance field, a global distance field around the camera and the sky; what they hit is lit from a surface cache of cards, lit ahead of time with their own multi-bounce radiosity. 41.2 dB in the Cornell room and 28.8 dB in the stress building, against 36.1 and 25.6 dB for radiance cascades, for 16–55% more per frame (see "Lumen GI" below).
  * Radiance cascades get **multi-bounce** light, and light their ray hits from per-light **light-visibility maps**, so they need no shadow rays.
* **Light-visibility maps:** each frame, every light traces a 128×128 map of the distance to the nearest geometry in each direction (smaller beyond 16 lights, so all the maps together always cost about as much as 16). The sun's map is orthographic instead, over the scene's bounding sphere. Secondary hits look up their shadowing there: from every light with up to 8 lights, otherwise from 4 lights picked by their unshadowed light. The path tracer can also use these maps for its bounces ("light bounces from light maps").
* **Upscaling (optional, macOS 26):** the frame is traced at low resolution with sub-pixel jitter, and MetalFX's denoising scaler (`MTLFXTemporalDenoisedScaler`) takes the raw 1-sample light and returns it denoised, sharper and anti-aliased at up to 3× the resolution, in place of SVGF and the shadow denoiser. It's on by default at 3×. Press **U** to cycle through off, 1.5×, 2× and 3×. Off (and on a GPU or system without the MetalFX denoiser) the frame is traced at the output resolution and this project's denoisers below filter it. The custom TAAU upscaler and MetalFX's temporal and spatial scalers were removed in October 2026; the results below still name them where they were measured.
* **Blue-noise sampling (on by default, B):** random numbers come from a 128×128 void-and-cluster blue-noise tile, shifted every frame by the golden ratio or the R2 sequence. Its stratified shadow samples steady the shadow denoiser's history clamp.
* **Shadow denoiser (direct light):** per light, direct light is an exact unshadowed term times the visibility of one random point on the light. Only that visibility is noisy, so only it is filtered (one light per channel; with more than 4 lights, one light group per channel), and the composite pass multiplies it back onto the exact unshadowed light. Shading is never blurred. The temporal pass clamps the reprojected history to what the current frame's neighbourhood allows, so moving shadows don't lag. Then up to 3 edge-aware 3×3 passes blur no wider than each light's penumbra, estimated from occluder distances, and skip 8×8 tiles that are fully lit or fully shadowed. This follows AMD FidelityFX's shadow denoiser and NVIDIA's SIGMA.
* **SVGF denoiser (indirect light):** temporal accumulation (16 frames) with motion vectors and disocclusion checks, then a 4-pass edge-aware à-trous wavelet filter guided by variance. It filters path-traced indirect light (or cascade light if you enable that). With the shadow denoiser off, it also filters direct light as before. The settings were tuned against converged reference images (see below).
* **Settings panel:** a floating **Render Settings** panel (Tab or ⌘,) has a control for every setting, including the GI method and its parameters and the denoiser parameters. It remembers your settings between launches and copies them as `METALRENDERER_*` variables (see [The settings panel](#the-settings-panel)).
* **Debug window:** a floating **Debug** window (I or ⌘I) shows a frame-time graph, GPU time per pass, the scene's instance, triangle and light counts, virtual geometry's cut and streaming, texture streaming, GPU memory and the ray queries' counters (see [The debug window](#the-debug-window)).
* **Exposure and tone curves:** exposure in stops and a choice of ACES (the default), AgX, Reinhard or none, applied in the composite pass before any upscaler.
* **Everything runs in compute kernels.** The shaders (`Shaders.metal` and the pieces in `Shaders/`) are compiled at runtime, so you can edit them while the app runs and press **R** to reload. A compile error names the file and the line.

## Build and run

You need Xcode 15 or newer and macOS 13 or newer.

```bash
cd MetalRenderer
swift run -c release
```

You can also open `Package.swift` in Xcode, choose **My Mac**, and press Run. Use the Release scheme for real frame rates.

> The app finds its shaders through its source path, so run it from this folder rather than copying the binary somewhere else. `METALRENDERER_SHADERS=<path to a Shaders.metal>` points it at another copy of them.

The window opens first; the shaders compile in the background (after an edit that takes two to three seconds, otherwise Metal has them cached and the first frame is there after a quarter of a second). If they fail to compile, the error is printed with the file and line, the window stays empty, and **R** tries again.

`swift test` runs the unit tests (`Tests/`): every setting's `METALRENDERER_*` name round-trips through Copy as Env and back, and no setting is missing from the settings table.

### Benchmark mode

```bash
METALRENDERER_BENCH=1 swift run -c release
```

This runs a fixed animation through a list of settings (GI bounces, denoiser, render scale, upscaling), times each GPU pass, prints a table, and quits. Set `METALRENDERER_BENCH_DIR=<folder>` to also save one PNG per setting. Benchmarks run without a window: no Dock icon, and the focus stays with whatever app is in front. They render into offscreen textures the size of the window on a Retina screen (1280×800 points at 2×), so the PNGs and timings match a windowed run; `METALRENDERER_WINDOW=1` shows the frames in the window instead. `METALRENDERER_BENCH=shot` renders one still of the default look (paused at t = 5 s; `METALRENDERER_SHOT_FRAMES` sets the frames after warm-up), to check what a change does with any of the `METALRENDERER_*` overrides below. Use `METALRENDERER_BENCH=quality` to render the same frames natively and with MetalFX instead, so you can compare the PNGs. Use `METALRENDERER_BENCH=noise` to render white- and blue-noise sampling next to converged reference images, made by averaging thousands of frames of the paused scene. Use `METALRENDERER_BENCH=denoise` to render a few frames for scoring denoiser changes against those references. Set `METALRENDERER_DENOISE`, for example `passes=3,tpasses=2,sigma=2,history=16,antilag=1,separate=1`, to override the denoiser in every setting without rebuilding (`tpasses` is the pass count with cascade GI).

Each pass runs in its own command buffer so it can be timed, which serializes the whole frame. A pass that runs in more than one buffer per frame (reflections, composite with its reference averaging) reports the sum; before October 2026 it reported only its last buffer. Set `METALRENDERER_BENCH_SPLIT=0` to encode frames exactly as the app does (one command buffer, with radiance cascades overlapping the denoiser) and report only whole-frame GPU time. `METALRENDERER_OVERLAP=0` turns that overlap off, for A/B timing. The table's last column, `cpu`, is the CPU's own work per frame (animation, uploads, encoding), without its waits for a frame slot and the drawable; the Debug window shows the same number as "encode".

Use `METALRENDERER_BENCH=shadow` to score direct-light denoising (static, moving and camera-move frames against a converged reference). `METALRENDERER_PAN=rotate` makes the camera-move ("pan") frames a pure rotation. `METALRENDERER_DENOISE` also takes `shadows=0` (SVGF for direct light), `spasses`, `shistory`, `sclamp` and `ssigma`. `METALRENDERER_GI` takes `blue` and `factor` (0 = no upscaling; see `Benchmark.swift`).

Use `METALRENDERER_BENCH=stress` to time the stress scene against light count (1 to 256), object count (0 to 2000) and GI method, and `METALRENDERER_BENCH=stressq` to score its direct light at 32 and 128 lights, and its final image, against converged references. `METALRENDERER_SCENE=stress,objects=400,lights=32` loads the stress scene in every setting of any mode. `METALRENDERER_LIGHTS=all` traces one shadow ray per light again (the brute-force baseline), `METALRENDERER_GI=lightrays=2` sets the shadow rays per light group, and `METALRENDERER_TLAS=<frames>` sets the rebuild interval of the top-level acceleration structure (1 = every frame). `METALRENDERER_BENCH_ONLY="32 lights|camera"` runs only the settings whose names contain one of these strings.

`METALRENDERER_MATH=relaxed` compiles the shaders with relaxed instead of fast math (infinities and NaNs behave exactly), to rule fast math out when an image looks off; `safe` also keeps the order of every operation. `METALRENDERER_VARIANTS=0` runs every kernel's general pipeline instead of its variant with the configuration's flags compiled in (see "Kernel variants" in the notes below), and `=log` prints each variant as it is made. `METALRENDERER_RT_STATS=1` compiles the ray queries' counters in (the Debug window can also turn them on), and benchmarks print them per setting: rays, and per ray the triangle and box candidates Metal's traversal handed the queries, in all and for each class of ray (camera, shadow, GI, specular, far, light map: what it is for, which a ray carries in bits 8–11 of its mask, `rayMask`, and the queries take off before Metal sees it). The path tracer's rays are the camera's. Metal can't count its nodes, so in those builds every triangle is non-opaque, to be counted as a candidate, and tracing is slower.

Use `METALRENDERER_BENCH=gallery` for the glTF gallery. It renders path-traced references (full BRDF, full-detail meshes, 4 bounces; skip them with `METALRENDERER_GI_REFS=0`), then the overview and a close-up with full-detail meshes and with virtual geometry at 0.5, 1 and 2 px, alternating so heat affects them alike, and the camera fly-through. Score it with `Tools/eval/gallery.py`.

These variables apply to the gallery and to models in general:
* `METALRENDERER_SCENE=gallery` starts the app in the gallery; `model=<path>` adds a model, as File > Open does.
* `METALRENDERER_GALLERY="owl|demon"` loads only the matching files; `METALRENDERER_ASSETS=<folder>` uses another folder.
* Virtual geometry:
  * `METALRENDERER_VG=0` turns it off; `METALRENDERER_VG_TAU=<px>` sets the allowed error.
  * `METALRENDERER_VG_MODE=clusters` uses the GPU-driven cluster variant (see below), with `METALRENDERER_VG_POOL=<MB>` for its page pool.
  * `METALRENDERER_VG_SYNC=0|1` forces background or synchronous cut updates; benchmarks run them synchronously.
  * `METALRENDERER_RASTER_VG=blas|clusters|mesh` picks how the raster visibility buffer draws it (see "Raster clusters" below), with `METALRENDERER_RASTER_VG_POOL=<MB>` (default 512) for the clusters' page pool; `METALRENDERER_RASTER_VG_BIAS=<k>` moves the rays from a drawn cluster k times its simplification error away from it (off by default); `METALRENDERER_BENCH=rastervg` renders the gallery, a close-up and a showcase model traced and with each way, direct light alone, the visibility buffer, cluster and LOD views, camera moves, and a 128 MB pool.
  * `METALRENDERER_VG_TEST=<model.glb>` builds a model's DAG, checks its invariants, round-trips the cache file and exits.
  * `METALRENDERER_BENCH=vgdebug` renders every geometry debug view at the gallery overview and close-up, with virtual geometry and (for triangles, triangle size and cost) full-detail meshes; set `METALRENDERER_BENCH_DIR` for the PNGs.
* Textures:
  * `METALRENDERER_TEXTURE_STREAMING=0` loads every texture whole, capped at `METALRENDERER_TEXTURE_SIZE` (default 2048).
  * `METALRENDERER_TEXTURE_BUDGET=<MB>` sets the streaming heap.
  * `METALRENDERER_TEXTURE_DEBUG=1` prints each texture's wanted and resident level.
* `METALRENDERER_SPECULAR=0` turns specular off.

For the lights:
* `METALRENDERER_SCENE=spots|sun|area|tubes|emissive|mixed|fog` starts in a light demo scene (`fog` = the Misty hall). `market` starts in the Night market; add `lights=16384` for the bulb count (`METALRENDERER_SCENE=stress,lights=4096` works the same way).
* `emissivelights=0`, added to `METALRENDERER_SCENE` or set as `METALRENDERER_EMISSIVE_LIGHTS=0`, turns emissive-mesh lights off.
* `METALRENDERER_SCENE=check=empty,model=Tools/test-assets/punctual-lights.gltf` shows the glTF light test file (a point, a spot and a sun) on an empty floor.
* `METALRENDERER_BENCH=lights` renders each demo scene paused at t = 5 s: direct light only, then each GI method, then moving. `METALRENDERER_LIGHTS_SCENES="sun|mixed"` picks scenes.
* `METALRENDERER_BENCH=speccheck` checks that direct specular light is counted once. It renders the studio, the stage and the garage with direct light only through each direct-light path (shadow denoiser, SVGF, ReSTIR) and against an accumulated reference; `Tools/eval/specular.py` prints each image's brightness over the reference's, which should be 1.00, its PSNR and its flicker.
* `METALRENDERER_BENCH=lightcheck` cross-checks the closed-form area lights. A rect, a tube and a sphere light are each rendered over a floor next to an emissive-mesh twin of the same shape and radiance, converged over 1024 frames. The mesh estimator is unbiased, so the pairs should match:
  * the sphere matches its twin within 0.1%;
  * the rect within 1%;
  * the tube within 7%, which is the extra light from the capsule twin's end caps.

For many lights:
* `METALRENDERER_DIRECT=auto|exact|grouped|restir` picks the direct-light method (`METALRENDERER_LIGHTS=all` is `exact`).
* `METALRENDERER_RESTIR="candidates=8,chains=4,temporal=1,maxm=8,spatial=1,k=4,radius=24,vis=0,split=0,sigma=3,passes=4,history=8,boost=2,grid=1,gcells=16,glevels=2,gsize=1,gscale=3,gslots=32,gk=8,gshare=6"` overrides ReSTIR's settings (these are the defaults; `g*` is the light grid: cells per axis, levels, the first level's cell size in metres, the size factor per level, reservoirs per cell, table candidates per reservoir, and how many of `candidates` come from the grid).
* `METALRENDERER_LIGHT_TABLE=1` or `0` forces the light-table shader variant on or off (normally on above 256 lights).
* `METALRENDERER_BENCH=restir` times the stress scene at 1 to 16384 lights with each method (exact up to 256, grouped up to 4096), then the Night market at 1024, 4096 and 16384 bulbs.
* `METALRENDERER_BENCH=restirq` renders direct light only (640×400) at 32, 128, 1024 and 4096 lights with each method, still and moving, against accumulated references (every light traced up to 1024 lights; above that, ReSTIR without reuse, which is unbiased). `METALRENDERER_BENCH=marketq` does the same in the Night market at 4096 bulbs, with ReSTIR's candidates from the table alone and from the light grid (plus the candidates alone, 64 frames averaged, for the samplers' own variance). `METALRENDERER_BENCH=restircheck` accumulates ReSTIR without reuse, from the table and from the grid, against every light traced in each light-type scene, to check both are unbiased. `Tools/eval/restir.py` scores all three.

For ReSTIR GI:
* `METALRENDERER_RESTIR_GI="quarter=0,bounces=2,lightmaps=0,feedback=1,dfeedback=1,fallback=1,temporal=1,maxm=2,age=30,spatial=0,k=2,unbiased=1,radius=30,dmin=0.02,denoise=1,sigma=3,passes=2,history=8,boost=2,antilag=0"` overrides its settings in every benchmark setting (these are the defaults).
* `METALRENDERER_BENCH=restirgicheck` accumulates indirect light (2 bounces, unclamped, no feedback) of path tracing against ReSTIR GI without reuse, with temporal and unbiased spatial reuse, and with the quarter budget, in the Cornell room and the stress hall. `Tools/eval/restirgi.py` scores it: the mean brightness ratios should be 1.00.

For the fog:
* `METALRENDERER_FOG=0` or `1` turns it off or on in every scene's preset.
* `METALRENDERER_FOG_SET="density=0.03,g=0.6"` overrides its settings. The keys are `on`, `density`, `falloff`, `base`, `g`, `ambient`, `noise`, `tile`, `far`, `haze`, `volumes` and `reflections`.
* `METALRENDERER_BENCH=fog` renders each fog scene paused at t = 5 s with cascade GI. It renders fog off, the preset, no local volumes, no fogged reflections, path-traced GI and the scattering view, then moving frames (natively and 3× upscaled).
* `METALRENDERER_BENCH=fogcheck` renders the froxel grid against a reference that marches every camera ray in 32 steps, each with its own shadow ray, averaged over 512 frames. It renders direct light only, as the scattering view and as the final image, for the Misty hall, the spots and the sun scene.
* Both fog modes take `METALRENDERER_LIGHTS_SCENES`.

For the crowd:
* `METALRENDERER_SCENE=crowd` starts in the Crowd scene; add `characters=32768`, `poses=128` and `detail=0`...`4` for its size, the number of poses the GPU animates and their level of detail (`METALRENDERER_SCENE="crowd,characters=8192,poses=64"`).
* `METALRENDERER_BENCH=crowd` times it against the number of poses, of characters and the level of detail, then renders a still and a camera move. With `METALRENDERER_CROWD_CHECK=1` every captured frame compares the vertices the GPU skinned with the CPU's.
* `METALRENDERER_CROWD=frozen` skips the per-frame skinning and refits: the crowd keeps the pose the CPU gave it at load.

For the city:
* `METALRENDERER_SCENE=city` or `citynight` starts in the City; add `seed=7` (the plants' seed too), `blocks=1`...`10`, `style=mixed|oldtown|residential|warehouse|office|modern`, `lit=0.5`, `rooms=0.3` and `textures=0` (`METALRENDERER_SCENE="citynight,blocks=1,style=oldtown"` is one block of old houses at night).
* `METALRENDERER_BENCH=city` renders it from above, from the road and in front of one building, a block of each style, flat against textured, and the night with the frame before; then times it at 1 to 100 blocks by day and at night.

For the sky:
* `METALRENDERER_SCENE=valley` starts in the Open valley.
* `METALRENDERER_SKY=constant`, `atmosphere` or an image path overrides every scene's sky.
* `METALRENDERER_SKY_SET="coverage=0.5,wind=20"` overrides the clouds. The keys are `clouds`, `coverage`, `density`, `base`, `thickness`, `scale`, `erosion`, `wind`, `winddir`, `shadows`, `strength`, `exposure` and `over` (clouds over an image).
* `Tools/test-assets/make-test-sky.py out.hdr [elevation] [azimuth]` writes a synthetic equirectangular test sky with a sun.
* `METALRENDERER_BENCH=sky` renders the valley at morning, forenoon, noon, afternoon and evening, from the ground and from the air, plus the sun and mixed scenes. It adds clear-sky, no-cloud-shadow and constant-sky variants, then moving frames. It takes `METALRENDERER_LIGHTS_SCENES`.
* `METALRENDERER_BENCH=skycheck` renders the valley in the afternoon, with a cloud shadow's edge in view. Each GI method runs against a 4-bounce path-traced reference, for the final image and indirect light, with cloud shadows on and off.

For the plants:
* `METALRENDERER_SCENE=forest` starts in the Forest; `trees=2500`, `undergrowth=100` (bushes, ferns and grass, percent) and `seed=1` change it. `seed` also picks the valley's trees.
* `METALRENDERER_SCENE=forest,cards=1` shows the trees' leaves as cards; `baked=1` bakes the plants into plain meshes, which stand still; `voxels=1` traces far plants as their voxels.
* `METALRENDERER_FOLIAGE="wind=0.4,dir=25,gusts=0.7,season=0.3,translucency=1,lod=2"` sets the Foliage section of the panel.
* `METALRENDERER_BENCH=forest` renders the forest paused (from the clearing, from above, close to a trunk, with 10,000 trees), then moving, natively and at 3×.
* `METALRENDERER_BENCH=forestcheck` renders the checks described under "Generated plants".
* `METALRENDERER_FOLIAGE_TEST=<seed>` builds every plant, times and checks them, and exits; with `METALRENDERER_FOLIAGE_TEXTURES=<folder>` it also writes the generated textures there as PNGs.
* `METALRENDERER_SCENE=world` starts in the Open world; `seed`, `trees` and `undergrowth` change it as they change the Forest, and `lit` the share of lit windows at night. Its day starts in mid-morning: `METALRENDERER_VIEW=tod=0.6` starts it at midnight (`tod=0.41` as the sun sets). `METALRENDERER_BENCH=worldnight` renders the night from a street, a street corner, above the first city and 2 km from it, then drives 600 m down a street; `METALRENDERER_BENCH=worlddusk` renders the first city from above and from a street at eleven times from afternoon to the next morning, then lets 20 s of dusk go by in each view; `METALRENDERER_BENCH=worldground` renders the first city's ground: a junction of two streets from above and from its corner, a courtyard, the last street and the fields beyond it, the roads from over the city and from 2 km, and the junction at night; `METALRENDERER_BENCH=worldroads` renders the road from the first city to the next one: from the junction it leaves by, from the fields, before its deepest cutting and its highest bank, in the woods, from above, all of it from over the city, from short of the other city and at night, then flies 600 m along it; with `METALRENDERER_SHOT_SWAP=<k>` a setting ends, and its picture is taken, `k` frames after its scene is first made again (around another tile, or with the cities' lights). `METALRENDERER_BENCH=world` renders it from where it starts, from a street, in the woods and from above, then flies 600 m across its tiles, and renders the start with the scene's origin elsewhere and a place 50 km out. `METALRENDERER_WORLD_TEST=<seed>` makes the tiles around the first city, says what they hold and how long they took, and exits. `METALRENDERER_WORLD_GROUPS=0` makes every tile's trees again with every scene, as the scene's own instances (for comparing with the groups they are in otherwise).
* `METALRENDERER_SCENE=physics` starts in the physics scene (`,bodies=…,particles=…,cloth=…,substeps=…,physics=gpu|cpu`). `METALRENDERER_BENCH=physics` renders it paused at 5 s under each API (the GPU's steps put everything in the same place under both) and with the CPU's steps, then times the first 5 s moving at 96, 512 and 2048 bodies on the GPU and 32 and 96 on the CPU. `METALRENDERER_BENCH=physicsdemo` records its demo, 30 s from the first drop along a camera track (`video.sh -m physicsdemo`).
* `METALRENDERER_SCENE=ragdolls` starts in the ragdoll scene (`,ragdolls=…,substeps=…,physics=gpu|cpu`). `METALRENDERER_BENCH=ragdolls` renders it paused at 5 s under each API and with the CPU's steps, then times the first 5 s moving at 8, 24 and 96 ragdolls on the GPU and 8 and 24 on the CPU. `METALRENDERER_BENCH=ragdollsdemo` records its demo, 20 s from the drop along a camera track (`video.sh -m ragdollsdemo`).
* `METALRENDERER_SCENE=hair` starts in the hair scene (`,hair=…` drawn strands a guide, `,fur=…` furry bodies, `,substeps=…,physics=gpu|cpu`). `METALRENDERER_BENCH=hair` renders it paused at 5 s under each API and with the CPU's steps, then times the first 5 s moving at 4, 12 and 24 strands a guide on the GPU and at 4 on the CPU. `METALRENDERER_BENCH=hairdemo` records its demo (`video.sh -m hairdemo`), and `hairviews` its views of the strands' light, albedo and normals and close-ups.
* `METALRENDERER_SCENE=softbodies` starts in the soft body scene (`,soft=…` soft bodies, `,cells=…` lattice cubes along each one's longest side, `,substeps=…,physics=gpu|cpu`). `METALRENDERER_BENCH=soft` renders it paused at 1.5, 3 and 5 s, under each API, with the CPU's steps and in its normals and direct light, then times the first 5 s moving at 16, 48 and 128 soft bodies on the GPU, at 16 with 10 cells, and at 16 and 48 on the CPU. `METALRENDERER_BENCH=softdemo` records its demo, 20 s from the throw along a camera track (`video.sh -m softdemo`).
* `METALRENDERER_SCENE=muscles` starts in the muscles scene (`,character=0|1`, `,fleshragdolls=…` ragdolls with flesh, `,flesh=…` the lattice's spacing in cm, `,skin=embedded|sliding`, `,body=skin|muscles` the character drawn as its skin or as an écorché, `,muscle=…` the muscles' strength, `,substeps=…,physics=gpu|cpu`). `METALRENDERER_BENCH=muscles` renders it paused at 2 and 5 s, under each API, with the CPU's steps, in its normals and direct light, close to the character in each skin, the écorché from its front, back and side, close to its chest, hips, shoulder, skull, knee, hand and spine, in its normals and as it dances, and to the ragdolls, then times the first 5 s moving at lattices of 5, 4, 3.5 and 3 cm, with 0 and 6 ragdolls, with the sliding skin, as the écorché and on the CPU. `METALRENDERER_BENCH=musclesdemo` records its demo, the character's whole 48 s routine along a camera track, and again as the écorché (`video.sh -m musclesdemo`).
* `METALRENDERER_SCENE=fluids` starts in the fluids scene (`,liquid=all|water|blood|honey`, `,solver=auto|pbf|mpm`, `,water=…,blood=…,honey=…` each liquid's solver, `,fluid=…` the most particles a liquid pours, `,physics=gpu|cpu`). `METALRENDERER_BENCH=fluids` renders it paused at 2, 4 and 6 s, at 6 s under each API, each liquid alone, all by PBF and all by MPM, in its normals and albedo, and path traced, then times the first 5 s moving on the GPU, 5 s from 12 s at 16k, 32k and 64k particles a liquid, and the first 5 s on the CPU at 2k. `METALRENDERER_BENCH=fluidsdemo` records its demo, its first 20 s along a camera track (`video.sh -m fluidsdemo`).
* `METALRENDERER_SCENE=shapes` starts in the SDF shapes scene. `METALRENDERER_BENCH=shapes` renders it paused under each API, then under Metal 3 with path tracing, ReSTIR and MegaLights on its glowing shapes, and in the normals, triangles (here: the shapes' materials) and traversal cost views; then it times moving frames and a camera move (settings named `<api> <what>`: `metal3 pt`, `metal4 cascades`). `METALRENDERER_BENCH=shapesdemo` records its demo: 30 s along a camera track with the showcase's lens, as a 30 fps JPEG sequence; `.claude/skills/offscreen/scripts/video.sh -m shapesdemo -o demo.mp4` makes the mp4 (with ffmpeg; it does `showcasevideo` too).
* `METALRENDERER_FLIGHT="x,y,z,frames"` flies the camera in every benchmark setting: metres a second, and with `frames` there and back again, turning every so many frames.
* `METALRENDERER_CACHE=0` makes everything a generated scene derives again (its textures, the plants' voxels, the world's tiles) instead of taking it from `~/Library/Caches/MetalRenderer/generated`. `METALRENDERER_CACHE_MB=4096` caps that folder.

The models in `Assets/` (596 MB) are stored with [Git LFS](https://git-lfs.com): install it before cloning (`brew install git-lfs && git lfs install`), or run `git lfs pull` afterwards. `.gitattributes` sends 3D models (`.glb`, `.fbx`, `.obj`, `.usd(z)`, `.blend`), HDR skies (`.hdr`, `.exr`) and the buffers and textures under `Assets/` to LFS. Put any glTF files there. The caches in `Assets/.metalrenderer-cache/` (4.4 GB for the 11 sample models: 1.9 GB of geometry DAGs, 2.5 GB of texture mip chains) can be deleted at any time; they're rebuilt on the next load.

Use `METALRENDERER_BENCH=gi` to compare the GI methods. It first renders 8-bounce, unclamped path-traced references by averaging thousands of frames of the paused scene; skip them with `METALRENDERER_GI_REFS=0` once you have them. Then, for each method, it renders a static frame, the next one (for flicker), an indirect-only frame, a moving frame, a frame at the end of a scripted camera move, and a frame with MetalFX on. `METALRENDERER_GI_MODES` picks the methods, for example `pt,pt-lightmaps,cascades,cascades-hq,restirgi,restirgi-q`. `METALRENDERER_GI` overrides GI settings everywhere, for example `mode=pt,bounces=4`, `mode=cascades,spacing=4,b1=0.25` or `mode=restir`. `METALRENDERER_TG`, for example `trace=16x8`, overrides a kernel's threadgroup size.

Use `METALRENDERER_BENCH=lumen` for Lumen GI: stills of eight scenes (the final image and indirect light alone) with distance fields, with triangles, without screen traces and without the cards, against the cascades, each "GI debug" view, then each method in a camera move for the timings (`METALRENDERER_BENCH_ONLY=camera`). `Tools/eval/lumen.py` scores it: how much of the G-buffer the fields cover, their depth error, and the indirect light with fields against the other variants. `METALRENDERER_LUMEN` overrides Lumen's settings (see "Lumen GI"), and `METALRENDERER_LUMEN_LOG=1` prints the bakes.

`Tools/eval/` scores the saved PNGs against reference images committed in `Tools/eval/refs/` (PSNR and flicker; see its README).

Use `METALRENDERER_BENCH=pathref` for the app's reference pictures (see "Reference rendering"): "Path traced" and "Accumulated passes" side by side, paused, in the Cornell room, the gallery, the area-light studio, the mixed-lights room, the emissive room, the stress hall (with window glass), the misty hall (fog) and the night market (4,349 lights), at 0.5× for 512 frames each (`METALRENDERER_PATHREF_FRAMES`); then the path tracer with the clock running and with the camera moving, where every frame starts over.

Use `METALRENDERER_BENCH=hwrt` to time ray tracing (in hardware from M3 on, in software before): moving frames through MetalFX's denoising scaler, path traced and with radiance cascades, in the Cornell room and the stress hall (`cornell pt`, `stress cascades`, …). `METALRENDERER_BENCH=hwrtq` renders the denoiser's frames for `Tools/eval/hwrt.py` to score against supersampled 1920×1200 references, and `METALRENDERER_BENCH=api` runs the same frames through Metal 3 and Metal 4 (settings `<scene>, metal3|metal4`; `METALRENDERER_API=metal3|metal4` picks the API for every setting). Settings that need something the GPU or the system lacks are skipped, and the run says which (`skipped: … (needs the MetalFX denoiser)`); `METALRENDERER_CAPS=rt,denoiser` keeps only the capabilities it names (`rt`, `hwrt`, `denoiser`, `metal4`, or `none`), to try that on a GPU that has them all. Without `rt` the renderer refuses to start, as it does on a GPU without Metal ray tracing. The results are under "Hardware ray tracing, MetalFX's denoiser and Metal 4".

Benchmarks render into offscreen textures, so the window server never paces them. With `METALRENDERER_WINDOW=1` it can: on an M4 Max under macOS 26.5 it handed drawables out at the display's rate (8.0–8.3 ms a frame) even though display sync is off. The pass that writes the drawable then waits for it, and its time, or the whole frame's with `METALRENDERER_BENCH_SPLIT=0`, reads as the display's period (8.0 ms for a frame that takes 0.8 ms); the GPU also idles between frames and clocks down, which inflates every other pass. If `span` sits near your display's period whatever the setting, this is happening. The M4 Max numbers in this file were taken into a texture.

The benchmark renders frames back to back without vsync, so the GPU's clock stays steady. Long runs can still throttle as the GPU heats up, so compare timings from short runs. The lists of settings are in `Benchmark+Modes.swift`, one function per mode.

## Controls

| Key | Action |
|---|---|
| Drag mouse | Look around (from a body in the physics scene: grab and drag it, release to throw it) |
| Scroll | While holding a body: farther (up) or nearer (down) |
| W A S D, Q E | Move, down/up (hold Shift to move 3.2× faster; the speed is in the panel) |
| Space | Pause animation |
| G | Toggle global illumination |
| M | GI method: path traced, radiance cascades, ReSTIR GI, Lumen |
| N | Toggle denoiser (shows the raw 1-spp signal) |
| [ ] | Fewer / more GI bounces (path traced, ReSTIR GI) |
| - = | Lower / raise render resolution |
| U | Upscaling (MetalFX denoiser): off, 1.5×, 2×, 3× (output is capped at the window's pixel size) |
| B | Toggle blue-noise sampling (on by default; the tile is generated once, in the background of the first launch, and kept in `~/Library/Caches/MetalRenderer`) |
| 1–8 | View: final, raw direct, raw indirect, normals, albedo, history length, indirect only, GI debug (cascades: probe grid over interpolation confidence) |
| 9, 0 | Cycle the geometry debug views (see below); back to the final image |
| L | Freeze LOD: virtual geometry keeps choosing detail for where the camera is now |
| T | Reference picture: off, accumulated passes, path traced (see "Reference rendering"; pause with Space to let it converge) |
| R | Hot-reload the shaders. It compiles in the background: the view keeps drawing with the old shaders until the new ones are ready, and keeps them if the compile fails |
| ⌘O, drop files | Add glTF models (`.glb` / `.gltf`) in front of the camera, or an HDR sky (`.hdr` / `.exr`) |
| Tab, ⌘, | Show or hide the Render Settings panel |
| I, ⌘I | Show or hide the Debug window |
| P | Show or hide the loading overlay (see "The loading overlay" below) |

The window title and the Debug window show the resolution, frame rate and GPU time. The panels never take keyboard focus, so the keys above keep working while it's open, and changes you make with the keys show up in it.

### The settings panel

* **Sections** fold with their triangles; the panel scrolls and can be resized, and keeps the size you drag it to. Rows that don't apply to the current mode are hidden (the stress scene's object count, each GI method's parameters, ReSTIR's, fog's while it's off).
* **Show advanced** (at the bottom) adds every remaining setting: ReSTIR DI's chains, confidence cap, neighbours, radius, the light grid's shape, split visibility and its own denoiser; ReSTIR GI's light maps, multi-bounce sources, caps, radius, minimum distance and its own denoiser; the shadow denoiser's history, clamp and edge tolerance; fog's base height, noise tile, wind and albedo; the clouds' thickness, size, erosion, wind direction and shadow strength; an HDR sky's exposure; and a Memory section (geometry pool, texture budget).
* **Camera and time:** exposure (EV) and the tone curve, the field of view, the move speed, the animation's speed, and, in the scenes with a day cycle, the time of day (an offset into the cycle that moves only the sun and the sky; it works while paused). In the Open world that is the whole day: 41% is sunset, 60% midnight. At their defaults (0 EV, ACES, 60°, 1×) images are bit-identical to before.
* **What the GPU can't run** stays listed and greyed out: the MetalFX denoiser (Rendering > Upscale, macOS 26) and Metal 4 (Scene > Graphics API, macOS 26). The launch log's first line says what was found (`Metal ray tracing: hardware, MetalFX denoiser: yes, Metal 4: yes (ray tracing: yes)`): ray tracing is in hardware on M3, A17 Pro and later, in software on the others. Metal ray tracing itself is not optional: a GPU without it is refused at launch ("This GPU doesn't support Metal ray tracing, which the renderer needs"). Metal 4 with ray tracing needs an Apple9 GPU (M3, M4); on M1 and M2 a Metal 4 setting falls back to Metal 3. A saved setting or an environment variable that asks for something missing falls back to the default with a line in the log.
* **Denoiser:** a caption says what the generic rows (passes, σ, history, anti-lag) filter in the current mode. ReSTIR DI and ReSTIR GI filter their own signal with their own settings, under Show advanced in their sections.
* **Remembered:** settings are saved (UserDefaults) half a second after each change and restored at the next launch, except the pause, the view, the reference picture, Freeze LOD and added models. `METALRENDERER_SETTINGS=default` starts from the defaults instead. Benchmarks never read or write them.
* **Copy as Env** puts the `METALRENDERER_*` variables that reproduce the current settings on the clipboard, listing only what differs from the defaults (fog and sky from the scene's preset). They work in a normal launch, where they override the saved settings, and in benchmarks, where they apply to every setting. A key the app doesn't know, or a value it can't read, is reported on the console and skipped. `METALRENDERER_DUMP_SETTINGS=1` prints the settings as JSON at startup, to compare two launches. The camera pose and where added models were placed aren't included.

The environment variables, in a normal launch and in benchmarks: `METALRENDERER_SCENE`, `METALRENDERER_GI` (now also `on=0` for GI off), `METALRENDERER_DENOISE`, `METALRENDERER_RESTIR`, `METALRENDERER_RESTIR_GI`, `METALRENDERER_FOG_SET` (now also `albedo=r:g:b` and `wind=x:y:z`), `METALRENDERER_SKY_SET`, and `METALRENDERER_VIEW="exposure=1,tonemap=agx,fov=70,speed=5,timescale=0.5,tod=0.25"` (plus `view=<index>` and `paused=1` outside benchmarks; `reference=off|accumulated|pt,refbounces=8,refspp=1,refmax=0` for the reference picture). The plain ones (`METALRENDERER_DIRECT`, `_API`, `_VG`, `_VG_TAU`, `_VG_POOL`, `_SPECULAR`, `_TEXTURE_BUDGET`, `_FOG`, `_SKY`) set defaults, as before.

### The loading overlay

A box in the bottom-left corner of the view shows what loads in the background, and how far it is. It comes up when
something has been loading for 0.3 s, and fades out 2 s after everything is done. It is drawn by AppKit over the view,
so frames, screenshots and benchmarks never have it. P (or Loading Progress in the app menu) turns it off, and on again;
the choice is kept.

* **A scene switch** (and a tile of the open world as the camera reaches it): its steps in order, each with a count,
  the item it is on, a bar and how long it took. **Shaders** (the pipelines, specialised for the scene's light types:
  1.5–3 s on an M1 Max, so the last six sets are kept, and a scene with light types seen before takes its set at once;
  R drops them), **Scene**
  (the gallery's and the showcase's models one by one, an added model, a first load's virtual geometry), **Textures**
  (each model's cache file, or the images decoded when textures don't stream), **Buffers**, **Metal BLAS** (by batch,
  with the MB built), **Virtual geometry**, and **Install** (on the render thread, after the frames in flight). The old
  scene keeps drawing until then. Picking another scene meanwhile drops the load: the gallery stops loading models and
  the BLAS stop between batches. A line on the console sums it up: `Loaded Gallery (Assets) in 2.4 s: shaders 1.5 s, …`.
* **Compiling shaders**, at launch and after R.
* **Streaming in:** what keeps coming once the scene is in. Texture levels and virtual geometry pages (and the cut's
  BLAS) while the new scene settles, for 20 s at most (later, as the camera moves, they stream without showing);
  Lumen's distance-field bakes, an HDR sky image, the noise tiles and shader variants whenever they are being made.

### The debug window

I or ⌘I shows it (it reopens at launch if it was open at quit). Everything refreshes twice a second; the graph, every frame.

* **Frame:** resolution, frame rate and GPU time, and a graph of the last 300 frames' GPU time (blue) and CPU frame interval (orange: the time between frame starts, so it includes waiting for the display), with their current, average and maximum and guides at 60 and 30 fps.
* **GPU pass timings** lists each pass's GPU time, averaged over half a second. Each pass then gets its own compute encoder, timestamped at its start and end (Apple GPUs sample counters only at encoder boundaries), and the encoders run one after another (a fence between each pair: without it, independent passes such as ReSTIR and fog overlapped and the sum came to 1.6× the frame time). The radiance cascades also no longer overlap the denoiser, so the frame is a little slower while it's on. MetalFX, its copy into the drawable and texture streaming can't be timestamped; they show as "other", the frame's GPU time minus the timed passes. It stops while the window is closed.
* **Scene:** instances (how many are virtual geometry), triangles over the non-virtual instances, lights by kind, whether the light table is on (more than 256 lights), the direct-light method Auto picked and the GI method.
* **Virtual geometry** (scenes with glTF models). With per-instance BLAS (the default): the meshes, the triangles traced this frame against the finest level's count (the cut's share), the clusters in the cut, the BLAS memory, the rebuilds (total and per second: each happens when an instance's cut changes, on a background thread and Metal's build queue) the last one's time, the last cut's time and how many instances it skipped as unchanged, the pixel error, and whether the LOD is frozen. With `METALRENDERER_VG_MODE=clusters`: clusters drawn against the 65,536 capacity (red when reached), groups resident in the streaming pool, the pool's use, requests waiting and groups loaded this frame. A popup switches between the final image and the geometry debug views, next to Freeze LOD.
* **Texture streaming:** resident megabytes against the budget, mip levels mapped, and megabytes uploaded since launch.
* **Memory:** what the GPU has allocated, and the working-set limit.
* **Ray queries:** turning the counters on recompiles the shaders with `RT_STATS` (a few seconds in the background, as with R); tracing is slower while they're on, since every triangle is then non-opaque. Then: rays per frame, and per ray the triangle candidates and the box candidates Metal's traversal handed the ray queries. Metal can't count its nodes: the candidates are what the counters can see of its work. They match what a benchmark with `METALRENDERER_RT_STATS=1` prints for the same view. The window reads the GPU's counters every frame and shows the increase, since a reset from the CPU doesn't stick while frames are in flight.

### Scene settings

| Setting | Default | Effect |
|---|---|---|
| Scene | Cornell room | Cornell room (5 objects, 2 moving, 3 lights), the stress test, the Gallery of glTF models in `Assets/`, or one of the light demos and the Misty hall (see below). Switching rebuilds the geometry and acceleration structures in the background, and picks that scene's fog and sky defaults (and resets the GI method to radiance cascades). Reset to Defaults also uses the current scene's. The gallery's first load builds its geometry and texture caches (about a minute for 11 models); later loads take seconds. |
| Objects | 400 | Stress test: props in the building, about 60% of them moving at 400 (see "The stress test" below). Applied when you release the slider. |
| Lights | 32 | Stress test: ceiling fixtures and lights that travel, 1 to 16384. Their total power stays the same, so the brightness barely changes; above 256 they also shrink. Night market: festoon bulbs, 4096 by default. |
| Characters | 2048 | Crowd: how many characters stand, walk and run in the square, 1 to 131072. Applied when you release the slider. |
| Poses | 64 | Crowd: how many poses the GPU animates each frame; every character shows one of them. More poses, fewer characters in step with each other. |
| Detail level | 3 | Crowd: the mesh the poses are skinned at. 0 is the full mesh (about 50k triangles), each level has half the triangles of the one before (level 3: about 6.5k). |
| City seed | 1 | City: which city is built, 0 to 999 (the same setting as the plants' seed, `seed`). Applied when you release the slider, as the others below. |
| City blocks | 4 × 4 | City: blocks along each side of the street grid, 1 to 10. |
| Building style | Mixed districts | City: every style by district, or one of them everywhere (old town, residential blocks, warehouses, office towers, modern mid-rise). |
| Lit windows | 35% | City at night, Open world: the share of windows with a light behind them, on at night. |
| Rooms behind windows | 15% | City: the share of windows with a room behind the glass instead of a blind, 0 to 50%. |
| Generated textures | On | City: brick, plaster, concrete, tile and paving textures. Off: flat colours. |
| Virtual geometry | On | Big glTF meshes as streamed level-of-detail cuts, each traced through a BLAS of its own. Off: full-detail meshes. |
| Geometry error | 1 px | The cut's allowed geometric error in traced pixels. 0.5 px: about 2× the triangles, closer to full detail; 2 px: half. Changes apply within a few frames. |
| Freeze LOD | Off | Keeps the cut chosen for the camera position at the moment it was turned on (title: "LOD frozen"). Fly up to a model to see the coarse geometry it gets from far away; turn it off and it refines within a few frames. |
| Specular | On | GGX specular for glTF materials (direct and reflections). Off: diffuse only, and no reflection pass. |
| Emissive surfaces are lights | On | Emissive geometry is sampled for direct light, with shadow rays, and lights GI through its light map. Off: it only lights what GI rays happen to hit, as before (radiance cascades ignore it entirely). Toggling it rebuilds the scene. |
| Direct light | Auto | Auto: ReSTIR above 256 lights, otherwise Grouped (which traces every light up to 4). Exact: one shadow ray per light, every frame (slow beyond a few dozen). Grouped: one light per colour group, picked over all lights. ReSTIR: see "Many lights" below. |
| Candidates | 8 per pixel | ReSTIR: light-table candidates per pixel and chain, plus one per sun. |
| Spatial reuse | 1 pass | ReSTIR: passes over 4 neighbours' reservoirs each (off, 1 or 2). |
| Temporal reuse | On | ReSTIR: resample last frame's reservoir (reprojected). |
| Visibility reuse | Off | ReSTIR: test the initial pick's visibility before reuse. Less noise but about 10% darker, because the target function ignores visibility. |
| Shadow rays | 1 per group + reuse | Grouped, with more than 4 lights: shadow rays per light group and pixel. "Reuse" keeps each pixel's light picks for up to 4 frames (ReSTIR-style temporal resampling): a third less flicker on still frames for about 0.7 ms. 2 rays per group halve the flicker and are the most accurate, for about 4 ms more at 400 objects. |

#### The stress test

A 40 × 8 × 40 m building in four zones round a cross-shaped aisle: a **warehouse** (pallet racks, an overhead conveyor, forklifts, carts, pickers) and a **factory floor** (two conveyor loops, robot arms, machines, gantry hoists) behind safety barriers at the back; a two-level **parking garage** (a deck on columns, a ramp, parked and circling cars) and an open-plan **office** (desk islands, chairs, people, delivery robots, glass meeting rooms) behind walls at the front. Its front wall has a garage entrance, a door and a window band to the sky. The default camera looks down the aisle from high over its front.

* **Objects** are props, one instance each: cartons in the rack slots, parcels and parts on the conveyors, vehicles, machines, desks, chairs, people and drones. A kind with fixed places (slots, bays, desks, lanes) takes no more than it has, and its share goes to the kinds with room left; drones (in each zone's airspace) always have room. About 60% move up to 400; at 2000 the racks hold 1256 cartons and 355 drones fly, and a third move. 0 leaves the empty building.
* **Lights** are exactly as many as asked, of the same total power: light j is in zone j mod 4, and every other one of a zone's is a ceiling fixture (high-bay spots, fluorescent tubes, LED panels, a few flickering) and the others travel (forklift and car headlights, cart and robot beacons, hoist spots, weld glows at the arms' grippers), each riding the vehicle, arm or hoist of the same slot. No prop glows, so these are all the scene's lights.
* Whole-frame GPU ms on an M1 Max (radiance cascades, MetalFX's denoiser 3× from 640×400, the custom BVH, since removed; `METALRENDERER_BENCH=stress` with `METALRENDERER_BENCH_SPLIT=0`):

  | 400 objects | 1 light | 4 | 8 | 16 | 32 | 64 | 128 | 256 |
  |---|---|---|---|---|---|---|---|---|
  | GPU ms | 6.64 | 10.73 | 11.38 | 13.71 | 15.35 | 16.67 | 18.10 | 20.54 |

  | 32 lights | 0 objects | 100 | 400 | 1000 | 2000 | path traced (400) | camera move (400) |
  |---|---|---|---|---|---|---|---|
  | GPU ms | 12.24 | 13.88 | 15.35 | 15.89 | 27.35 | 35.41 | 14.18 |

  Quality at 640×400 against the converged references (`METALRENDERER_BENCH=stressq`, `Tools/eval/stress.py`): direct light 29.4–29.5 dB still and moving at 32 lights, 27.4 dB at 128; the final image against an 8-bounce path-traced reference 25.7 dB with radiance cascades, 27.7 dB path traced, 31.0 dB with ReSTIR GI; MetalFX's denoiser at 3× against supersampled frames 29.3 dB (albedo) and 26.9 dB (direct light).

  ReSTIR DI, its light grid and MegaLights, accumulated without reuse, match tracing every light here (mean brightness ratio 1.00, 47–48 dB, `METALRENDERER_BENCH=restircheck`).
* `METALRENDERER_BENCH=stressdemo` records its demo: a 58 s tour (the overview, down a warehouse aisle, the factory's walkway, the office, the garage's upper deck) along a camera track with the showcase's lens, as a 30 fps JPEG sequence; `.claude/skills/offscreen/scripts/video.sh -m stressdemo -o demo.mp4` makes the mp4.
* Every run builds the same building (seeded). It replaced a 20 × 6 × 20 m hall of floating and bouncing cubes and spheres lit by drifting sphere lights in October 2026: the figures in this README quoted for "the stress hall" or "the stress scene" were measured in that hall, unless a table says otherwise.

### Light types

Each light demo is procedural, so it loads at once. Each demo scene shows one light type, and every light in it moves, sweeps or flickers.

| Type | Shape and units | Diffuse | Specular | Demo scene |
|---|---|---|---|---|
| Sphere | Sphere of radius r; intensity I (power 4πI) | Exact for a sphere above the horizon | Representative point (Karis 2013) | Cornell, gallery (the stress test has spheres, spots, tubes and rects) |
| Spot | A sphere light with a smooth falloff between an inner and an outer cone | As the sphere × cone | As the sphere × cone | **Spot lights**: a stage with six coloured spots sweeping their beams |
| Sun | Direction and angular radius (0.27°); irradiance E | E cos / π | Reflection vector clamped into the sun's disc | **Sun and sky**: a courtyard and a room lit only through its windows, with a one-minute day cycle that also changes the sky colour |
| Rect | One-sided panel; radiance L | Exact polygon form factor (Lambert), clamped at the horizon | Representative point on the rect | **Area lights**: softboxes, a ceiling strip and a window panel over a roughness ramp of glossy spheres |
| Tube | Capsule of length ℓ and radius r: a cylinder of uniform radiance with the power of a sphere light of intensity I | Exact line integral for a Lambertian cylinder, clipped to the horizon | Nearest point of the segment to the reflection ray, then sphere | **Tube lights**: a garage with fluorescent tubes and neon (one flickering) |
| Emissive mesh | Any geometry with an emissive material, textured or not | One triangle per pixel, picked by emitted power, one shadow ray, denoised by SVGF | Seen by the reflection rays | **Emissive meshes**: a dark room with neon letters, a glowing orb, a screen and a spinning ring of coloured cubes |

**Mixed lights** has every type at once: a living room at dusk with:
* a low sun through the window;
* a ceiling panel;
* a desk spot lamp;
* a tube under a shelf;
* a TV screen;
* a floor lamp.

How the types fit the existing pipeline:
* **Shared helpers.** Every type answers the same five questions in `Shaders/Lights.metal`:
  * `lightUnshadowed`: diffuse light, which is also each light's picking weight;
  * `lightShadowTarget`: a random point of the light, for the shadow ray;
  * `lightSpecular`;
  * `penumbraWidth`, for the shadow denoiser;
  * `lightMapVisibility`.
  Every kernel goes through these, so the many-lights picking, reuse, the shadow denoiser and all three GI methods work with any mix of types.
* **No cost for unused types.** A light's type is packed next to its shadow-denoiser group, and the pipelines are specialised (a Metal function constant) for the scene's set of types. A scene with only sphere lights compiles to the old code and runs at the old speed. Switching to a scene with a new set of types re-specialises the pipelines, which takes about 1.5 s the first time.
* **Emissive meshes.** They take a separate path, because the shadow denoiser needs an exact unshadowed term that a mesh doesn't have:
  * Each emissive instance becomes one light, with a bounding-sphere-and-normal proxy. The proxy is used for picking it and for its light map in GI.
  * `meshLightsKernel` picks one triangle per pixel and casts one shadow ray to it. Its result is denoised by its own SVGF signal and added in the composite.
  * GI rays ignore those surfaces' emission, as they ignore the light spheres, so their light isn't counted twice.

Costs at 960×600 on an M1 Max, measured with surfel GI (since removed):

| Scene | GPU time |
|---|---|
| Spots | 5.0 ms |
| Sun | 4.1 ms |
| Area | 7.6 ms |
| Tubes | 9.4 ms |
| Emissive | 8.2 ms |
| Mixed | 11.7 ms |

* **Rect lights:** four of them cost 3 ms of trace time, for their form factors and shadow rays.
* **Mesh lights:** the mesh-light pass costs 1.5–2.4 ms, mostly its shadow ray.

### Many lights (ReSTIR DI)

With hundreds or thousands of lights, the grouped picker still loops over every light per pixel, and the light maps trace one map per light. ReSTIR DI (Bitterli et al. 2020) replaces both with work that doesn't depend on the light count.

* **Light table** (`LightTable.swift`). Built once per scene: every analytic light but the suns, plus every emissive-mesh triangle, in a Vose alias table weighted by nominal power, mixed with 10% uniform probability so a dim light close to a pixel still gets picked. It sits after the lights in the per-frame light buffer. Moving and flickering lights change only the target function, never the table. Up to 2 suns are drawn separately, one candidate each per pixel, combined by multiple importance sampling.
* **Light grid** (ReGIR, Boksansky et al. 2021; `regirBuildKernel`). The table knows power, not position: in a 64 m street most of a pixel's table draws are bulbs tens of metres away. So every frame the GPU rebuilds a camera-centred world-space grid of light reservoirs from the current lights: 2 levels of 16³ cells (1 m and 3 m cells, 16 m and 48 m across), 32 reservoirs per cell, each the pick of 8 table draws by an orientation-free target (luminance toward the cell centre over the squared distance, clamped to the cell's half diagonal; cosines, cones and facing dropped, so it's positive for every light that could reach the cell, which keeps a draw from it unbiased), stored with its W. That's 262k reservoirs (4 MB) built in 0.65 ms, whatever the light count, and nothing on the CPU: moving, swaying and flickering lights are simply in next frame's grid. The grid's origin is jittered by up to a cell every frame. It is bound with the scene, so the secondary hits (the path tracer's next-event estimation, the cascades' and ReSTIR GI's hits, the reflections' hits) draw all but one of their RIS candidates from it, and the fog resamples 3 grid and 1 table candidates (plus the suns) by their unshadowed in-scatter in place of its weighted loop over a 32-light subset, which also made the fog pass cheaper.
* **Sample and target.** A sample is (light element, a point on it as two 16-bit coordinates). Points move with their light, so reusing a sample needs no Jacobian. The target function is the luminance of the sample's unshadowed diffuse plus specular light at the pixel.
* **`restirTemporalKernel`**: per pixel and chain, 8 candidates plus the suns, resampled by the target: 6 from the grid (a reservoir of the pixel's cell, the cell jittered by up to half a cell per candidate so neighbouring cells blend in, weighed target × its W / 8) and 2 from the table (target / (8 pdf)); outside the grid, all 8 from the table. The constant 1/8 for both sources keeps the mix unbiased; the table draws cover what a cell's 32 reservoirs missed. Then last frame's reservoir at the reprojected pixel (depth and normal tests), merged with the generalized balance heuristic. That uses last frame's light positions, so moving lights stay unbiased. Confidence is capped at 8 frames.
* **`restirSpatialKernel`**: 4 neighbours in a 24 px disc rotated every frame, merged with pairwise MIS. Then one shadow ray per chain. There are 4 independent chains per pixel, each with its own share of the neighbours, so the frame traces the same 4 rays per pixel as the grouped picker.
* **Denoising.** ReSTIR's output is radiance, not per-light visibility, so SVGF filters it (σ 3, 4 passes, 8 frames of history) with its variance doubled, because reused samples are correlated and look steadier than they are. Direct specular goes into the reflection pass's signal.
* **Above 256 lights**, the shaders are specialised with a light-table flag (`LIGHT_TABLE`):
  * the light maps are off (one per light would cost N·32² rays, and more than 2048 can't be allocated);
  * GI's direct light at secondary hits (cascades, path-tracer bounces) and the path tracer's next-event estimation draw 8 candidates from the table, with one shadow ray;
  * the sky pixels draw only the suns' discs.
* **Night market** (`Scene+Lights.swift`): a 64 m street with 32 festoon strings (a quarter of them chasing), 80 swaying lanterns, 40 stall canopies and about 60 windows as rect lights (some flickering), 24 neon signs as emissive meshes (10k triangles), 60 walking shoppers and a moon, in light fog.

Whole-frame GPU ms on an M1 Max (stress scene, 400 objects, radiance cascades, custom upscaler 3× from 640×400; `METALRENDERER_BENCH=restir` with `METALRENDERER_BENCH_SPLIT=0`):

| Lights | 1 | 4 | 32 | 256 | 1024 | 4096 | 16384 |
|---|---|---|---|---|---|---|---|
| Exact | **4.35** | **7.32** | 30.53 | 231.83 | — | — | — |
| Grouped | 4.38 | 7.35 | **8.97** | **12.05** | 19.68 | 52.76 | — |
| ReSTIR, table only | 8.93 | 10.23 | 11.45 | 12.55 | **13.83** | **15.46** | **17.12** |
| ReSTIR + light grid (default) | 9.10 | 10.45 | 11.60 | 12.75 | 14.14 | 15.62 | 17.30 |

| Night market bulbs | 1024 | 4096 | 16384 |
|---|---|---|---|
| Grouped | 33.91 | 87.01 | — |
| ReSTIR, table only | **18.04** | **18.46** | **18.73** |
| ReSTIR + light grid (default) | 18.85 | 19.17 | 19.31 |

From 32 to 16384 lights, ReSTIR's frame grows by 5.7 ms, while the light count grows 512×. It costs about 4.4 ms more than the grouped picker at 1 light (the extra passes and their denoiser) and breaks even near 256 lights. The light grid adds 0.2–0.3 ms in the stress hall and 0.6–0.8 ms in the market (its 0.65 ms build overlaps the trace, and the fog pass gets 0.2–0.4 ms cheaper). The market rows are from after its bulbs, windows and canopies became static instances (below): that took 0.3–0.6 ms off every ReSTIR row there and left the stress hall, where every light moves, unchanged. (The ReSTIR rows are a later run than the Exact and Grouped rows, with the Debug window's counters in the build; same machine.)

Quality, direct light only (640×400, PSNR against accumulated references, `METALRENDERER_BENCH=restirq`, `Tools/eval/restir.py`; flicker is the mean frame-to-frame change on a still frame, mean is brightness against the reference). References trace every light up to 1024 lights; at 4096 they are ReSTIR without reuse, accumulated, which is unbiased:

| Lights | Method | Static | Flicker | Moving | Mean |
|---|---|---|---|---|---|
| 32 | Exact | **37.80 dB** | **0.15** | 34.87 dB | 1.00 |
| 32 | Grouped | 36.73 dB | 0.74 | **35.28 dB** | 1.04 |
| 32 | ReSTIR | 34.32 dB | 0.59 | 31.04 dB | 1.00 |
| 128 | Exact | **40.11 dB** | **0.12** | 36.96 dB | 1.00 |
| 128 | Grouped | 37.55 dB | 0.92 | **37.35 dB** | 1.04 |
| 128 | ReSTIR | 35.35 dB | 0.61 | 32.02 dB | 1.00 |
| 1024 | Grouped | **38.06 dB** | 0.90 | **37.90 dB** | 1.03 |
| 1024 | ReSTIR | 35.17 dB | **0.65** | 32.19 dB | 1.00 |
| 4096 | Grouped | **37.05 dB** | 0.93 | **36.84 dB** | 1.03 |
| 4096 | ReSTIR | 34.34 dB | **0.68** | 31.87 dB | 1.00 |

ReSTIR is 2.3–2.9 dB below the grouped picker on still frames and 4.2–5.7 dB below in motion, where SVGF's history is short. It flickers less, and its brightness is right where the grouped picker's is 3–4% high.

* **The light grid in the Night market** (4096 bulbs, 640×400, against accumulated references; `METALRENDERER_BENCH=marketq`):
  * Direct light: the candidates alone, 64 frames averaged, score 35.3–35.8 dB from the table and 38.1–38.2 dB from the grid; after reuse and SVGF, a still frame scores 32.9–33.1 dB from the table and 33.3–33.6 dB from the grid, with the same flicker. In the stress hall, whose equal lights fill the room, the grid changes nothing (±0.1 dB).
  * Indirect light alone (view 6, against a 2048-frame path-traced reference): a denoised path-traced frame 29.6 → 30.0 dB, a cascades frame 28.7 → 29.2 dB; 256 raw path-traced frames averaged 26.4 → 27.2 dB, mean 1.03 → 1.01.
  * The fog's scattering alone (view 14, against the per-pixel reference march): the froxel grid 39.7 → 40.7 dB, the march itself over 128 frames 41.7 → 43.6 dB, mean 1.00 either way. What mattered: without the per-candidate cell jitter, every pixel of a cell drew from the same 32 reservoirs, and the grid scored 0.8–1.0 dB *below* the table in both scenes (correlated candidates reuse badly); 16 reservoirs per cell lose 0.8 dB; a third level (144 m) or 16 draws per reservoir add nothing a 640×400 frame can show for twice the build.
* **Unbiased:** accumulated ReSTIR without reuse, from the table and from the grid, matches tracing every light in every light-type scene (rect, tube and sphere lights and their emissive-mesh twins, spots, tubes, area, emissive, mixed, the stress hall): mean brightness ratio 1.00, 39–65 dB (`METALRENDERER_BENCH=restircheck`). With reuse, it stays at 1.00 (table above).
* **Below Grouped quality at low light counts.** Grouped's shadow denoiser filters only visibility and multiplies it back onto an exact unshadowed term, so shading stays sharp. ReSTIR's noise is in the radiance itself, and SVGF has to blur it. So Auto switches to ReSTIR only above 256 lights, where Grouped's per-pixel loop starts to dominate the frame.
* **What lost:**
  * Visibility reuse (testing the initial pick before reuse): about 10% darker, since the target ignores visibility.
  * Zeroing occluded samples' weights after shading: 30% darker, because the confident zeros spread through reuse.
  * Denoising visibility (shadow denoiser) and unshadowed light (SVGF) apart: one visibility channel can't hold coloured shadows (4% too bright).
  * One chain instead of 4: cheaper, but visibly noisier. Sharing one set of candidates across the chains: −1.5 dB at 1024 lights.

### Indirect light (ReSTIR GI)

ReSTIR GI (Ouyang et al. 2021) keeps the path tracer's one path per pixel but reuses its first bounce. A sample is the path's first hit point x_s, its normal and the light L leaving it toward the pixel (everything the rest of the path gathered).

* **Exact reconnection.** Secondary hits shade as diffuse here (their albedo doesn't depend on the direction), so L is the same toward any pixel, and another pixel can reconnect to x_s exactly. Samples are treated as points on surfaces (area measure), so the Jacobian of a reconnection is part of the target function: luminance(L) × the pixel's cosine lobe × cos at x_s / distance².
* **The path tracer's own lobe.** The pixel's lobe is the path tracer's direction pdf (cosine about the shading normal, with directions below the triangle mirrored above it), not cos/π, so a fresh sample's estimate equals the path tracer's.
* **`restirGIInitialKernel`**: the path, with the path tracer's bounces, next-event estimation and sky, as a reservoir (M = 1, W = 1/pdf). Its last hit adds last frame's denoised indirect light where that point was on screen, and last frame's mean indirect light elsewhere (as the radiance cascades do).
* **`restirGITemporalKernel`**: last frame's reservoir at the reprojected pixel (depth and normal tests), merged by confidence, capped at M = 2. A sample older than 30 of its pixel's fresh paths is dropped, since its light was gathered under old lights.
* **`restirGISpatialKernel`**: optional spatial reuse (off by default), then one visibility ray to the pick, skipped when it is the pixel's own fresh path. It writes the indirect light, which SVGF denoises (σ 3, 2 passes, 8 frames, variance doubled for the correlated samples).
* **Unbiased spatial reuse.** A neighbour's samples are hit points of its own paths, so it can never produce a point it doesn't see. Weighing its technique as if it could darkened the stress hall by 8%. With unbiased reuse on, the targets include visibility: one ray from each neighbour to this pixel's sample and one from this pixel to each neighbour's. Without them it is cheaper but 8–17% darker in the stress hall.
* **Quarter budget** (optional): one thread per 2×2 block traces a rotating pixel, so each pixel gets a fresh path every 4th frame. Sample ages count only those frames; counting every frame dropped long-lived samples, which are the bright ones, and darkened the image by 2–6%.
* **Unbiased:** without feedback, accumulated ReSTIR GI matches accumulated path tracing in the Cornell room and the stress hall, without reuse, with temporal and spatial reuse, and with the quarter budget: mean brightness ratio 1.00 in each (`METALRENDERER_BENCH=restirgicheck`).

Settings panel (Global illumination, with ReSTIR GI selected):

| Setting | Default | Effect |
|---|---|---|
| Rays | 1 per pixel | 1 per 2×2 pixels: the quarter budget (see below). |
| Bounces | 2 | Path length; the first bounce is the reused sample. Also `[` and `]`. |
| Multi-bounce | On | The paths' last hits add last frame's indirect light (on screen) or its mean (off screen). |
| Temporal reuse | On | Resample last frame's reservoir (reprojected). |
| Spatial reuse | Off | 1 or 2 passes over 2 neighbours' reservoirs each. |
| Unbiased spatial reuse | On | Visibility in the spatial targets: two rays per neighbour. |

Quality (640×400, against the 8-bounce path-traced references; `METALRENDERER_BENCH=gi` and `stressq`, `Tools/eval/gi.py` and `stress.py`; mean is the indirect light's brightness against the reference's) and whole-frame GPU ms at the default setting (custom upscaler 3× from 640×400, `METALRENDERER_BENCH_SPLIT=0`, M1 Max):

| Cornell room | GPU ms | Static | Contact crop | Indirect only | Mean | Moving | Camera move | Flicker |
|---|---|---|---|---|---|---|---|---|
| Path traced, 2 bounces | 8.6 | 25.7 dB | 24.4 dB | 21.1 dB | 0.76 | 25.6 dB | 25.5 dB | 0.30 |
| Radiance cascades | **2.9** | 36.1 dB | 34.7 dB | 31.1 dB | 0.95 | 36.1 dB | 36.1 dB | **0.05** |
| **ReSTIR GI** | 8.4 | **42.2 dB** | **43.3 dB** | **38.8 dB** | 1.01 | **41.9 dB** | **41.7 dB** | 0.45 |
| ReSTIR GI, quarter budget | 4.8 | 41.8 dB | 42.6 dB | 38.1 dB | 1.01 | 36.7 dB | 26.5 dB | 0.37 |

| Stress hall, 32 lights | GPU ms | Static | Contact crop | Indirect only | Mean | Moving | Camera move | Flicker |
|---|---|---|---|---|---|---|---|---|
| Path traced, 2 bounces | 19.3 | 32.5 dB | 35.1 dB | 27.0 dB | 0.81 | 31.3 dB | 31.2 dB | 0.66 |
| Radiance cascades | **9.0** | 25.5 dB | 28.0 dB | 22.2 dB | 0.92 | 25.3 dB | 25.3 dB | 0.76 |
| **ReSTIR GI** | 21.5 | **36.4 dB** | **38.2 dB** | **34.5 dB** | 1.02 | **35.8 dB** | **35.6 dB** | 0.71 |
| ReSTIR GI, quarter budget | 12.4 | 35.6 dB | 37.3 dB | 33.3 dB | 1.02 | 28.6 dB | 27.1 dB | **0.60** |

* **Gallery close-up** (PBR, full detail): 33.5 dB, against 31.6 dB path traced and 30.8 dB with cascades.
* **Night market** (4096 bulbs, fog off, against an 8-bounce reference rendered for this test): 30.4 dB, against 30.0 dB path traced and 29.5 dB with cascades. Whole frame: 27.6 ms, against 26.8 and 18.7 ms (with the scene's fog).
* **Why it isn't the default:** it costs 2–3× as much as radiance cascades (8.4 vs 2.9 ms in the Cornell room). The paths cost what the path tracer's do: 5.2 ms at 640×400 in the Cornell room and 12 ms in the stress hall.
* **The quarter budget** is 1.7× cheaper and nearly as good on still frames (−0.4 to −0.8 dB), but a pixel that loses its history (disocclusion, camera moves) waits up to 4 frames for a fresh path: −5 to −15 dB in motion. So it's off by default.

What mattered, measured with these benchmarks:
* **Multi-bounce feedback.** With 2 bounces and nothing more, the image reaches 77–81% of the reference's brightness, and ReSTIR GI scores like the path tracer (25.9 and 31.7 dB). Last frame's indirect light where the path ends on screen raised that to 31.4 and 34.3 dB. The mean of last frame's indirect light for points off screen raised it to 42.2 and 36.4 dB.
* **A third bounce** adds 1.4 dB in the Cornell room and 0.8 dB in the stress hall, for 2.5 and 6 ms more. So the default is 2.

What didn't help:
* **Reuse doesn't lower the error here; it lowers flicker.** On raw frames, temporal reuse is a big gain: the stress hall's indirect light goes from 13.4 to 18.1 dB and its flicker from 41 to 7.2. After SVGF, though, no reuse at all scores as well or slightly better: 43.1 and 36.6 dB still, 42.8 and 36.1 dB moving. But it flickers about 40% more (0.62 and 1.04, against 0.45 and 0.71). The denoiser already averages over time, and reused samples lag behind moving lights. That's why the confidence cap is 2: a cap of 16 costs 0.5 dB on still frames and 2–4.5 dB in motion.
* **Spatial reuse.** Unbiased, it adds no PSNR after the denoiser, whatever the neighbour count (1 to 5), and costs 3–12 ms for its rays. Before visibility was part of the targets, it even added noise: picks a pixel couldn't see contributed nothing. So it's off by default.
* **The denoiser's settings** (σ 2–5, 1–3 passes, history 4–16, variance boost 1–4) moved scores by at most 0.5 dB. Anti-lag never triggers: the raw signal is too noisy for its test.
* **One bounce** with feedback costs about 5 ms in the Cornell room and scores 35.5 dB, below the cascades' 36.1 dB at 2.9 ms.

### Lumen GI

The third step of the Unreal Engine 5-style pipeline (`METALRENDERER_GI=mode=lumen`, **M** or the panel's GI method; `Lumen.swift`, `LumenCards.swift`, `LumenScene.swift`, `LumenGlobalSDF.swift`, `MeshSDFBuilder.swift`, `Shaders/Lumen*.metal`): Lumen's software mode, a GI method next to the cascades. Rays trace distance fields instead of triangles, and what they hit is lit from a surface cache lit ahead of time.

* **Screen probes.** One probe per 8×8 pixels, on a jittered G-buffer pixel of its tile, with 64 equal-area octahedral directions (rotated every frame by an R2 offset). Each probe's radiance is filtered with its 3×3 neighbours (plane distance and angle-error weights), projected to L1 spherical harmonics, resolved per pixel and accumulated over 16 frames, as the radiance cascades' last steps do.
* **A ray goes, in order:**
  * **Screen:** a closest-depth pyramid (from the G-buffer's depth) marched for 24 steps, out to 50 m, with a thickness test. A hit reads last frame's lit diffuse light, which the composite writes for it (`FLAG_GI_RADIANCE`). A ray that leaves the screen or passes behind something goes on in the world from where it was last safe.
  * **Mesh distance fields:** out to 2 m, against the instances listed for its tile (a cull pass gives each tile of 4×4 probes up to 63 instances), in each instance's object space.
  * **The global distance field:** beyond that, to the end of its clipmap.
  * **The sky** on a miss.
* **Mesh distance fields** (`MeshSDFBuilder`): a signed field per mesh, baked on the CPU in the background and cached (`msdf`, `hfld` in the generated cache). Voxels are the mesh's largest side over 116 (at least 2 cm). Sparse 8³ bricks (7³ cells, faces shared) hold the band of ±4 voxels as `r8Snorm`, and a 16³ coarse grid of unclamped distances covers what lies beyond it. The sign comes from a flood fill from the border; a mesh with no inside, and an open surface that closed geometry surrounds (the world's ground around its buildings), is two-sided. Flat, gently sloped meshes (terrain, the ground, the rooms' quads) are **heightfields** instead: up to 256² heights, solid below. Every geometry kind has a field: shared and streamed meshes, virtual geometry (from a coarse cut of its cluster DAG) and plants (one field per assembly, from all its parts; a hit on one takes its wood's and its leaves' colours mixed by the share of its area that is leaves, as its far voxels do). The crowd (screen traces only) and swaying ground cover have none. Benchmarks wait for the bakes.
* **The global distance field** (`LumenGlobalSDF`): 2–6 clipmap levels of 128³ cells around the camera (0.1 m at the finest, 0.2 m outdoors, doubling), toroidal, each cell the nearest distance to the instances' fields and which instance that is. Bricks of 8³ cells are composed again where they enter a level, where a moving instance was or is, and when a bake lands: up to 4096 a frame, the finest first. A hit is moved onto its owner's mesh field (two Newton steps) and lit through that instance's cards.
* **The surface cache** (`LumenCards`): each instance but plants gets up to 6 cards, the faces of its box, sized by how big it looks (8–128 texels, with hysteresis), in a 2048² atlas of 128² pages. A card is captured once, by rays from its face into the box (albedo, normal, depth, emission), and then lit: direct light by the cascades' hit lighting (`giLightIllum`), up to 1M texels a frame, and **radiosity**, the cards' own indirect light, from a probe per 4×4 texels with 8 rays into the scene that read the other cards: up to 256K texels a frame, new cards first, averaged over 8 updates. Hits read albedo × (direct + indirect) + emission from the card facing them. Plants have no cards (a card sees a canopy's outer, sunlit leaves, and the hits inside it read them): their hits are lit where they are, without last frame's light on screen near them (in a canopy that is often another leaf's).

Settings panel (Global illumination, with Lumen selected; `METALRENDERER_LUMEN="spacing=8,history=16,screen=1,cards=1,radiosity=1,rrays=8,rbudget=256,trace=sdf,reach2=2,steps=24,thickness=0.03,reach=50"`, the defaults):

| Setting | Default | Effect |
|---|---|---|
| Probe spacing | 8 px | 4 or 16. |
| Screen traces | On | Off: every ray starts in the world. |
| Surface cache (cards) | On | Off: hits are lit where they are, by the hit lighting (at a field's hit, the material's colour times its texture's average). |
| Trace | Distance fields | Triangles: ray queries against the scene's triangles in place of the fields, as an A/B. |
| Radiosity | On | Off: the cards get no indirect light (one bounce, plus the screen's). |
| Radiosity budget | 256K texels | Up to 1024K: every card a frame. |
| Radiosity through distance fields | Off | Radiosity's rays trace the global field instead of triangles, as Lumen does: cheaper outdoors, 1–1.4 dB worse. |
| GI debug view | Probes | Trace kinds (screen, world, cards, mesh field, global field, sky), card albedo and light, the fields' normals and depth check, the global field. |

Quality (640×400, against the 8-bounce path-traced references; `METALRENDERER_BENCH=gi` and `stressq`, `Tools/eval/gi.py` and `stress.py`; mean is the indirect light's brightness against the reference's; the other rows are from "Indirect light (ReSTIR GI)"):

| Cornell room | Static | Contact crop | Indirect only | Mean | Moving | Camera move | Flicker |
|---|---|---|---|---|---|---|---|
| Radiance cascades | 36.1 dB | 34.7 dB | 31.1 dB | 0.95 | 36.1 dB | 36.1 dB | **0.05** |
| ReSTIR GI | **42.2 dB** | **43.3 dB** | **38.8 dB** | 1.01 | **41.9 dB** | **41.7 dB** | 0.45 |
| **Lumen** | 41.2 dB | 41.4 dB | 36.4 dB | 0.98 | 38.6 dB | 38.8 dB | 0.40 |

| Stress hall, 32 lights | Static | Contact crop | Indirect only | Mean | Moving | Camera move | Flicker |
|---|---|---|---|---|---|---|---|
| Radiance cascades | 25.5 dB | 28.0 dB | 22.2 dB | 0.92 | 25.3 dB | 25.3 dB | 0.76 |
| ReSTIR GI | **36.4 dB** | **38.2 dB** | **34.5 dB** | 1.02 | **35.8 dB** | **35.6 dB** | 0.71 |
| **Lumen** | 35.1 dB | 36.1 dB | 31.9 dB | 0.92 | 33.9 dB | 33.5 dB | **0.54** |

| Stress building (since October 2026) | Static | Contact crop | Indirect only | Mean | Moving | Camera move | Flicker |
|---|---|---|---|---|---|---|---|
| Radiance cascades | 25.6 dB | 26.4 dB | 25.0 dB | 1.13 | 25.6 dB | 25.5 dB | **0.96** |
| ReSTIR GI | **31.0 dB** | **27.7 dB** | **35.3 dB** | 0.98 | **30.9 dB** | **30.4 dB** | 1.08 |
| **Lumen** | 28.8 dB | 27.5 dB | 30.3 dB | 0.92 | 28.9 dB | 28.5 dB | 1.01 |

* Moving objects cost Lumen more than the other methods (−2.6 dB in the Cornell room): most likely because its probes' 16-frame history and the cards' radiosity, averaged over 8 updates, lag behind them.
* **Leaves against the sun** (`METALRENDERER_BENCH=forestcheck`, against a 512-frame path-traced reference): 32.7 dB (32.6 dB with triangles) and 0.8% too bright, against 32.2 dB for the cascades, 33.4 dB for ReSTIR GI and 33.5 dB path traced.

Cost: whole frames on an M1 Max at the default setting (640×400 → MetalFX 3×), in each scene's camera move (`METALRENDERER_BENCH=lumen METALRENDERER_BENCH_ONLY="lumen camera" METALRENDERER_BENCH_SPLIT=0`, the cascades by `METALRENDERER_GI=mode=cascades`; medians of three alternating rounds with `ab.sh`), and the memory Lumen holds:

| Scene | Cascades | Lumen | | Mesh fields | Global field | Cards |
|---|---|---|---|---|---|---|
| Cornell room | 5.8 ms | 8.2 ms | +43% | 3 fields, 2 MB | 2 levels, 24 MB | 96 MB |
| Stress hall (before October 2026) | 10.9 ms | 16.9 ms | +55% | 3, 2 MB | 3, 36 MB | 96 MB |
| Stress building | 14.2 ms | 21.5 ms | +51% | 32, 8 MB | 4, 48 MB | 96 MB |
| Gallery | 13.7 ms | 18.8 ms | +38% | 24, 2 MB | 3, 36 MB | 96 MB |
| Sun | 5.4 ms | 7.7 ms | +44% | 3, 2 MB | 4, 48 MB | 96 MB |
| City | 7.8 ms | 11.8 ms | +51% | 100, 129 MB | 6, 72 MB | 96 MB |
| Forest | 46.7 ms | 59.6 ms | +28% | 30, 16 MB | 6, 72 MB | 96 MB |
| Crowd | 11.0 ms | 12.8 ms | +16% | 2, 2 MB | 6, 72 MB | 96 MB |
| Open world | 13.9 ms | 18.8 ms | +36% | 309, 129 MB | 6, 72 MB | 96 MB |

* **Where it goes** (per pass, split mode): the probes' trace takes 1.2–3.4 ms (the cascades' 0.5–2.6 ms), 4.7 ms in the forest (the cascades' 10.4 ms), and the cards' radiosity 1.0 ms in the Cornell room, 2.1 in the stress hall, 3.3 in the gallery, 4.0 in the world and 18.6 in the forest, whose plants are expensive to trace and whose camera move keeps resizing cards (new cards get radiosity whatever the budget). The rest (capture, direct light, probes, cull, filter, SH, resolve, the global field's bricks) is 0.6–1.7 ms.
* **The radiosity budget:** every card every frame (1024K texels) cost 3 ms more in the stress hall, 4.6 in the gallery, 7.3 in the world and 24 in the forest, for 0.05 dB on still frames and 0.1–0.3 dB in motion. 64K texels lost 1.2 dB in the Cornell room.
* **The first bake** takes 60 s for the city and 58 s for the open world, 7 s for the forest, on all cores in the background; from the cache it takes under half a second. Until a field is baked its instance is missing from the field traces.

How close the fields are to the triangles (`METALRENDERER_BENCH=lumen`, `Tools/eval/lumen.py`): coverage is the share of G-buffer pixels whose surface the fields find (a ray from the camera), the error is the depth's mean where both do (it saturates at 10 cm), and the rest compare indirect light with fields (the default) against triangles, against no screen traces and against no cards:

| Scene | Coverage | Depth error | Fields vs triangles | vs no screen traces | vs no cards |
|---|---|---|---|---|---|
| Cornell room | 1.000 | 2.7 cm | 49.5 dB | 48.3 dB | 36.4 dB |
| Stress hall (before October 2026) | 1.000 | 3.5 cm | 38.9 dB | 41.7 dB | 35.6 dB |
| Stress building | 0.991 | 2.7 cm | 32.5 dB | 31.7 dB | 37.5 dB |
| Gallery | 0.999 | 2.9 cm | 41.2 dB | 46.8 dB | 43.9 dB |
| Sun | 0.996 | 4.1 cm | 37.9 dB | 38.3 dB | 40.4 dB |
| City | 0.995 | 7.8 cm | 40.9 dB | 22.8 dB | 39.3 dB |
| Forest | 0.986 | 9.0 cm | 41.4 dB | 46.1 dB | 41.6 dB |
| Crowd | 0.970 | 5.2 cm | 35.9 dB | 33.0 dB | 41.0 dB |
| Open world | 1.000 | ≥ 10 cm | 40.3 dB | 28.1 dB | 32.7 dB |

The crowd's characters have no fields (screen traces only), the open world's 256 m tiles get 2.2 m voxels, and the city and the world lean most on screen traces (their windows and streets).

What mattered:
* **The surface cache with radiosity.** The first gather (probes traced on triangles, multi-bounce from last frame's screen) scored 37.2 dB in the Cornell room and 33.0 dB in the stress hall; with screen traces, the cards and their radiosity in place of the screen feedback, 41.2 and 36.1 dB (on triangles).
* **Fields for everything:** the world's ground was invisible to the fields until open surfaces inside closed meshes counted as two-sided; the forest's ground was lit as if white until hits took the texture's average colour.
* **The global field's hit threshold** is half a voxel: a quarter leaked light through thin walls (the stress hall 53% too bright).
* **Foliage.** Leaves against the sun were 2.8% too bright (31.4 dB), and the error sat in the shade: the trunks' undersides and the dark canopy, the darkest pixels 49% too bright. Taking plants out of the cards, lighting a field's hit on a plant with its leaves' and wood's mixed colour (not its wood's), and no multi-bounce feedback at leaf hits made it 32.7 dB; the Cornell room and the stress building render as before.

What didn't help:
* **Radiosity through the global field** (Lumen's way): −1 dB in the Cornell room and −1.4 dB in the stress hall, where its voxels lose the near contact. It is an option.
* **Finer global voxels, more instances per brick or per tile:** none closed the stress hall's gap between fields and triangles.
* **More probes for foliage.** Probes every 4 px instead of 8 scored 31.3 dB against 31.4 dB in the backlit forest, so adaptive probes (at most a quarter more, where interpolation fails) weren't built. No multi-bounce feedback anywhere cost 0.9 dB in the Cornell room and 2 dB in the stress building; the probe's own pixel in place of the frame's mean, for hits off screen, changed nothing.

### Volumetric fog

The fog is a participating medium with single scattering. It has two parts:
* **Height fog:** exponential above a base height, constant below it.
* **Local fog volumes:** up to 8 per scene. Each is a box or a sphere, with its own density, albedo, edge softness, height falloff and noise, and it can move.

A tiling 3D noise texture (three octaves of gradient noise, 64³) drifts with the wind and breaks both into patches. Light scatters with a Henyey–Greenstein phase function. Its anisotropy sets how much brighter the fog is looking toward a light. Every light type scatters with ray-traced shadows, including emissive meshes, and an ambient term (the sky colour × a factor) stands in for indirect light.

**Camera view.** The fog lives in a froxel grid: camera-aligned voxels of 8×8 traced pixels by 64 slices, spaced exponentially from 0.2 m to the fog's distance. Each frame:
1. **`fogInjectKernel`** lights one random point in each froxel.
   * The point is kept in front of the surface its pixel sees, so light from behind walls and above ceilings doesn't leak into the froxels that straddle them.
   * It picks one light, mostly by its unshadowed light × the phase function and 10% of the time uniformly. The uniform share keeps lamps from being picked too rarely where an unshadowed sun dominates the weights; rare picks show as speckles.
   * It traces one shadow ray. The analytic optical depth of the fog toward the light dims the result: closed form for the height fog, overlap length for the volumes. For the sun, that depth is taken only to the edge of the scene's bounding sphere, so fog and surfaces get the same sunlight.
   * The result is blended into last frame's grid, reprojected (10% new).
2. **`fogIntegrateKernel`** accumulates in-scattered light and transmittance front to back along each froxel column. It uses an energy-conserving step (Hillaire 2015).
3. **The composite** reads both at each pixel's depth and applies them before tonemapping. With a temporal upscaler, the lookup moves by the frame's jitter scaled to one froxel, so the upscaler smooths the grid's steps.

**Reflections.** Reflection rays are dimmed by the analytic transmittance. In-scattered light comes from one point at a random distance along the ray, lit by one light sample with one shadow ray; the reflection denoiser removes its noise.

**Accuracy** (`METALRENDERER_BENCH=fogcheck`, against the per-pixel reference). This is direct light only at 960×600. The grid matches the reference except for blur finer than a froxel.

| Scene | Scattering: mean light | Scattering: PSNR | Final image: mean | Final image: PSNR |
|---|---|---|---|---|
| Misty hall | +0.3% | 34.5 dB | +1.8% | 32.9 dB |
| Spot lights | −0.3% | 43.4 dB | +1.4% | 38.7 dB |
| Sun and sky | −1.4% | 48.6 dB | −0.1% | 42.0 dB |

| Setting | Default | Effect |
|---|---|---|
| Fog | per scene | On in the Misty hall and in the spot, sun, tube, emissive and mixed demos. Off in the Cornell room, the stress test, the gallery and the studio. |
| Density | per scene | The height fog's extinction at and below its base height, from 0.002 to 0.3 per metre (0 leaves only the volumes). |
| Height falloff | per scene | How fast the height fog thins with height, per metre. |
| Forward scattering | per scene | Henyey–Greenstein g, from −0.3 to 0.9. Higher values make shafts and beams brighter when you look toward their light. |
| Ambient light | per scene | The sky colour × this lights the fog evenly. |
| Noise | per scene | How much the drifting noise breaks up the height fog. |
| Distance | per scene | The froxel grid's far end, from 10 to 150 m. Fog stops accumulating beyond it, including on the sky. |
| Haze beyond | 0 (Open world: 0.4) | Beyond the grid the height fog goes on at this share of its density, to the surface or, on the sky, without end: in closed form along the camera ray, lit like the grid's far half (what was scattered in there per unit of light taken away). It hides where a large scene ends. 0 = none. |
| Local fog volumes | On | The scene's volumes: ground mist in the hall and the garage, haze over the stage, a glow around the orbs, dust in the sun scene's room. |
| Fog in reflections | On | One more shadow ray per reflection pixel. |
| Lights scatter in it | On (Open world: off) | Off: only the sun (or the moon) and the sky light the fog, not the scene's other lights. A froxel takes one light sample a frame: among a city's thousands of lamps and windows that scatters in blotches. |

The view menu's last entry, "Fog scattering", shows the fog's in-scattered light alone.

**The Misty hall** is a long stone hall built for the fog:
* a low sun beyond the far wall shines in through three tall mullioned windows, toward the camera, and swings slowly;
* a searchlight high on the left wall sweeps the right half of the hall;
* mist pools over the floor around a lantern;
* a glowing orb sits in its own cloud.

Fog pass cost on an M1 Max (the fog passes don't depend on the GI method):

| Scene | 960×600 | 640×400 (the default, 3× upscaled) |
|---|---|---|
| Misty hall | 1.6 ms | 0.76 ms |
| Spot lights | 0.66 ms | 0.48 ms |
| Sun and sky | 0.32 ms | 0.19 ms |
| Tube lights | 1.2 ms | 0.61 ms |
| Emissive meshes | 2.1 ms | 1.0 ms |
| Mixed lights | 0.66 ms | 0.34 ms |

The cost follows the froxels in front of the surfaces and the lights' sample paths. Emissive meshes are dearest: 18 mesh lights, each sample a triangle pick. Fogged reflections add up to 0.8 ms at 960×600, on the stage, whose floor is glossy everywhere. With fog off, frames are unchanged and cost the same.

**Limitations:**
* Fog doesn't dim the light that reaches surfaces.
* GI rays ignore the fog; its only indirect light is the ambient term.
* There is no multiple scattering.
* Shafts and beams narrower than a froxel (8 traced pixels) are blurred.
* A froxel that contains a point light averages its very bright core, so the source looks like a small square glow.

### Sky and clouds

The sky is one texture, read wherever the sky is seen: camera rays, GI rays (all three methods), reflection rays and the fog's ambient light.
* **Layout:** each hemisphere is an equal-area square, 1024² with mips: Shirley–Chiu's concentric map, then Lambert's. A texel is about 0.14°, roughly a traced pixel at 640×400.
* **Updates:** `skyKernel` redraws a sixteenth of the texels each frame. It dispatches only those, so no SIMD lanes idle. A scene switch or settings change redraws them all (but not the Open world's next scene around the camera: its sky is the same sky).
* **Sun disc:** drawn per camera pixel, darkening toward its limb and dimmed by the clouds in front of it. GI rays never see it; next-event estimation delivers the sun.
* **Constant sky:** scenes with a constant sky skip all of this and render exactly as before.

**Atmosphere** (Hillaire 2020):
* **Model:** single scattering in an Earth-sized atmosphere (Rayleigh, Mie, ozone), marched in 20 steps per texel. It is lit through a transmittance table and has a multiple-scattering table; both are computed once.
* **Sun light:** `Atmosphere.swift` computes the transmittance toward the sun on the CPU, and the sun light's colour follows it. In Sun and sky, the day cycle now colours itself, as do the valley's mornings and evenings.
* **Exposure:** it is fixed, so the valley's sun stays at least 10° up; below that the sky is 20–50× darker than at noon. (The Open world's sun does set: there its light is turned up as it sinks, see "The day and the night" under "Open world".)
* **A second source:** the atmosphere can be lit from two directions at once (`SkyParams.glow`, a second march of a texel's 20 steps while it is set). The Open world uses it at dusk and dawn: the moon is the light, and the sun under the horizon still lights the sky.
* **Stars** (the Open world's night): one texel in 500 of the upper hemisphere, most of them faint, dimmed toward the horizon. They are in the texture, behind the clouds, a texel (0.14°) across.

**Clouds** are a spherical shell, by default 1.5–3 km up (the valley's are lower and smaller). Their shape:
* coverage from a slow 2D field;
* a height profile: rounded bases, thinning tops;
* Perlin–Worley base noise, eroded by Worley detail (Schneider 2015).

The noise is tiling 3D textures, generated once on the GPU with mips. Each sample reads the level that matches the march's step length. Long steps toward the horizon would otherwise alias the tiled noise into streaks, so the fine erosion fades out where it can't be resolved.

Clouds are lit by:
* the sun, through a 5-step march toward it, with three scattering orders (Wrenninge) and a two-lobe phase function (silver linings);
* the clear sky around them (`skyMeanKernel` averages 64 directions). Using the clouded sky instead would make clouds dark under their own darkness.

They are marched in 40 jittered steps per texel and blended into the texel's last value. They sit kilometres away, so a direction-only texture is right for a camera that moves metres.

**Cloud shadows:**
* `cloudShadowKernel` traces the clouds' transmittance toward the sun every frame, 256² over the ground around the scene.
* Every sun visibility test multiplies by it (`sunVisibilityScale`), so all paths see the same clouds: shadow rays, the shadow denoiser's visibility, next-event estimation, the light maps used by cascades and path-tracer bounces, and the fog.
* Real cumulus are larger than these scenes. The valley's clouds are small and low (800 m features, 700 m up) so that their shadows visibly cross it.

**HDR images** (`.hdr`, `.exr`, equirectangular):
* Open one with File > Open or drag and drop, or pick "HDR image" in the Sky popup.
* The brightest compact spot, if it outshines the sky 50 times, becomes the sun. Its direction and irradiance drive the scene's sun light, and its texels are replaced by the ring around it, so it isn't counted twice.
* The image is scaled so that sun plus sky light a level floor with about 4 units.
* The volumetric clouds can be drawn in front of it ("Clouds" with an image sky).
* With the test image the sun is found exactly where it was drawn.

| Setting | Default | Effect |
|---|---|---|
| Sky | per scene | Constant colour (indoor scenes), Atmosphere (Sun and sky, Mixed lights, Open valley) or HDR image. |
| Clouds | On | With an image sky: clouds in front of it. |
| Coverage | per scene | 0 = clear, ~0.3 scattered cumulus, 1 = overcast. |
| Cloud density | 0.03 /m | Extinction inside a cloud. |
| Cloud height | per scene | The layer's base altitude (its thickness and noise scale come with the scene). |
| Wind | per scene | The clouds and their shadows drift with it. |
| Cloud shadows | On (off in Mixed lights) | The clouds shadow the scene. |

Sky pass cost on an M1 Max (every sky texel is updated each 16 frames, so it doesn't depend on the resolution):

| Sky | Cost |
|---|---|
| Atmosphere with clouds and cloud shadows (valley) | 0.8–1.0 ms |
| Atmosphere with clouds (Sun and sky, Mixed lights) | 0.5 ms |
| Clear atmosphere | 0.23 ms |
| HDR image | 0.17 ms |

The first frame of a sky also draws the noise and the atmosphere's tables, and redraws every texel (about 10 ms, once).

**Limitations:**
* The exposure is fixed: low suns are dark.
* The camera can't fly into the clouds (the sky is direction-only).
* Cloud shadows cover a square around the scene's bounding sphere.
* An image's sun needs a sun light in the scene to land on; without one, the image still lights GI.

### Generated plants

The plants are made at load time from a seed (`Foliage*.swift`); nothing is read from disk. The design follows Unreal Engine 5.7's Megaplants (the Procedural Vegetation Editor, Nanite Assemblies, skinning and voxels), adapted to a renderer that only traces rays.

**The generator** is a chain of plain functions over a `Recipe`:
* **Grower:** recursive, parametric growth by levels (trunk, limbs, twigs), in the manner of Weber and Penn, inside a crown shape. A plant's age (sapling, young, mature) scales its levels, lengths and counts.
* **Modifiers:** curvature, gravity and light (a pull up or down per level), and carving against an ellipsoid (bushes).
* **Mesher:** stems as tubes with fewer sides per level and one vertex at the tip; ribbons for fern stalks and grass. A mesh's size is counted first and filled by index, in parallel, one slot per plant.
* **Leaf distributor:** leaves along the twigs by phyllotaxis (spiral, two rows, whorls), in a shuffled order, so any leading part of them is a random sample.
* **Graft distributor:** each species has six **boughs** (a twig with side twigs and leaves, 330–850 triangles). A tree hangs them on its limbs, turned and scaled, a few hundred times.
* The same seed gives the same plants, built in parallel or on one thread (`FoliageTests`).

The whole library (7 species, 29 plants, 24 boughs) takes 1–2 ms on an M4 Max.

**The Forest** is 320 m of rolling ground (a heightfield, 205k triangles) with a level clearing around the camera and a trail leading out. Trees stand on a jittered grid, thinned by slope and a noise; conifers take the hills, oaks the low ground, birches the clearing's edge and the trail. Bushes and ferns grow under them, and grass in 2 m patches of 800 blades around the clearing. The valley's trees are the same plants.

**In Metal's structures** (`PlantTracing.swift`, `Shaders/Foliage.metal`):

| Megaplants feature | Here |
|---|---|
| Nanite Assemblies | A third instancing level, by Metal's multi-level instancing (`max_levels<3>`). An assembly's parts are the instances of an instance structure of its own, a *variant*, and a plant's top-level instance names one; a part is a placed mesh. The forest stores 283k triangles instead of 2.25M. An assembly has a variant per phase of the wind (8, `PLANT_PHASES`) and, if it drops its leaves, per share of them still on it (5: none, a quarter, half, three quarters, all), so 40 for a deciduous assembly and 8 for an evergreen. A plant names the variant of its phase's bucket and of its quantised share. |
| Skinning and wind | Every part has two rigid bones (its limb, and itself on that limb), and the plant leans about its foot. With wind, every frame `plantWindKernel` poses the variants' parts (the bones at the variant's phase and the mean gust) and Metal refits the variants plants name: under Metal 4 side by side in the frame's encoder, under Metal 3 two to an encoder (three or more instance refits in one encoder crash the M1 Max's driver). Only the plants within the sway reach (`swayReach`, "Sway reach", 20 m by default) name posed variants; farther ones name their assembly's variant at rest, built once and never refitted, and still lean as a whole. With time paused (and nothing else changed) nothing is posed, written or refitted. Plants of the same bucket swing their boughs together; the whole plant's lean is each plant's own, in its instance's transform (`Wind.plant` mirrors the shader's `plantWind`). The shading turns the hit point at this frame's time and the last one's, so moving leaves have motion vectors. Grass and ferns have no bones: a patch's instance is sheared downwind by its height (`Wind.cover`). |
| Nanite Voxels | Each plant has a 32-voxel grid with two coarser levels (1.7 MB for the forest). A voxel holds its optical depth, its share of leaf and its mean normal. With "Far plants as voxels" (off by default, below), a plant whose voxels are about 2 traced pixels (the `lod` setting) names its grid's box at that level instead of its variant, and the ray queries march it; a ray stops in a voxel with the probability that it would have hit something there. Every ray sees a plant the same way, since the level goes by the camera. |
| Seasons | The Season setting recolours the leaf materials, each shade of each species in its own time, and from late autumn drops leaves: in a variant for fewer leaves, a leafy part's structure is over a prefix of its mesh's triangles (the leaves are shuffled, and fall from the end). Conifers keep theirs. |
| Two-sided foliage | A share of the leaves (35% for broad leaves) shows the light of its far side: for those, lighting, shadow rays and bounces use the flipped normal. Which leaves is fixed per leaf. It is an approximation: a leaf is lit from one side or the other, never both. The path-traced reference does the same, so the GI methods agree with it (below) without that proving it right. |

**Textures** are generated too (`FoliageTextures.swift`): furrowed bark, birch bark, a veined leaf, a needle, a grass blade, and a colour map of the forest's ground (moss, the clearing, the trail, rock on slopes). A plant's texture is detail on its material's colour and has a fixed mean, so a plant's far voxels, which use the colour alone, match its triangles (within 1% from above).

**Leaves as cards** (`cards=1`, off by default): each stretch of twig becomes two crossed rectangles showing a picture of the twig with its leaves, cut out by an alpha mask. The mask's texel coordinates ride in the spare floats of the card's triangles. Card meshes are non-opaque, and the ray queries' loop tests their candidate triangles against the mask (`rtCutout`). In software ray tracing that is slow (below).

| Foliage setting | Default | Effect |
|---|---|---|
| Wind | 0.4 where there are plants | 0 = still, 1 = strong. At 0 the wind code is compiled out of the kernels. |
| Wind direction, Gusts | 25°, 0.7 | Where it blows to; how much it comes in waves, which travel downwind. |
| Season | 0.3 | 0 = spring, 0.3 = summer, 0.5–0.8 the leaves turn and fall, 1 = winter. |
| Leaf translucency | 1 | Scales every species' share of backlit leaves; 0 = opaque leaves. |
| Distance LOD (voxels) | 2 px | The voxel size, in traced pixels, at which a plant is marched instead of traced. 0 = never. At 4, near trees turn visibly grainy. |
| Far plants as voxels | Off | Far plants as their voxels instead of their triangles: the assemblies in a scene that moves, picked every frame, and baked plants in a still one. Slower wherever it was measured (below). `voxels=1`. |
| Trees, Undergrowth, Plant seed | 2500, 100%, 1 | The Forest. Applied when the slider is released. |
| Leaves as cards, Plants as plain meshes | Off | See above. |

**Voxels** (`VoxelLOD.swift`, `VoxelGrids.swift`, `PlantTracing.swift`). Baked plants have the assemblies' grids (the same cells: one builder, `FoliageVoxels.Plant`). Each grid level is a bounding-box structure of one box, whose primitive data names the grid and the level. A far assembly's instance names its grid's box at its level, picked every frame; a far baked plant's wood instance points at its level's box and its leaf instance is masked out. The ray queries become intersection queries: the traversal hands each box it meets to the shader, which marches it (`rtVoxels`) and keeps the nearest hit itself, while triangles stay the traversal's own. The levels go by the camera, Freeze LOD and the `lod` bias included.
* A still scene's instance structure is built once, for tracing. When the camera has moved a metre, the levels are picked again on the CPU (the open world's 700,000 plant instances in 14 ms) and another structure is built in the background (36 ms on an M1 Max) and swapped in at a frame's start: the levels trail the camera by a few frames, and the frames trace as fast as before. Benchmarks rebuild at the frame's start and wait, so their pictures don't depend on timing.
* Measured on an M1 Max (software ray tracing), the forest from above, 960×600: the voxels have the triangles' mean brightness (73.8, 77.2, 67.6 against 73.8, 76.7, 67.9) and the LOD view matched the custom tracer's (since removed) plant for plant. But the intersection queries cost every ray about 30% (`forest`, every view, no plant as voxels), more than far plants as voxels save (9% of the frame from the air, nothing from the ground).
* Measured on an M4 Max (hardware ray tracing, Metal 4; `METALRENDERER_BENCH=forest` and three views of `worldroads`, medians of 3 alternating rounds): the intersection queries alone cost a frame 3–15%. With far plants as voxels the forest takes 4.7–9.6 ms a frame against 2.6–4.9 ms with triangles, and the open world's views 8.7–11.5 ms against 2.7–3.8 ms. The cost is the hand-over: every box a ray meets stops the hardware's traversal and gives the ray back to the shader. Handing the road views' boxes over without marching any takes 8.4–9.4 ms a frame; marching them all adds 1–2 ms. The hardware gets through a far tree's triangles faster than it gets to the shader and back.
* So far plants are triangles by default, on every Mac. With voxels on by default wherever there is ray-tracing hardware, the open world took 14–72 ms a frame here (`METALRENDERER_BENCH=world`) instead of 2.9–5.1 ms.
* But in the wind the forest's frame is a little faster with voxels (M4 Max, "forest moving", 960×600: 16.5 ms against 17.2): a far plant as a box has no variant to refit, and the wind's pass takes 8.5 ms instead of 11.7, more than the boxes cost the trace (3.05 against 2.10 ms) and the cascades' rays (2.03 against 1.25).
* **Not kept: GI rays' level of detail** (`raylod`: a GI ray marches a far plant's grid no finer than its cone needs where it meets it, as the custom tracer did, where it made the open world's frames 7–10% faster). On Metal's tracer it can only coarsen the plants that are boxes already, and what a box costs is the hand-over, not the march: in the moving forest with voxels the cascades' rays took 2.03 against 2.01 ms (the picture within RMS 0.4), and from the air, every far plant a box (`forestcheck`, "baked voxels aerial", 3 alternating rounds), 3.13 against 3.19 ms and the frame 11.34 against 11.54. Giving the plants that are triangles to the camera a box for the GI rays alone would put the hand-over on every GI ray that meets a plant, which the numbers above say costs more than the triangles.
* **Not built: the camera's level picked in the shader** (the custom tracer's `cameraVoxelLevel`, which spared its prep pass writing a level into every plant's record). Here the CPU picks the levels and a changed pick builds the top-level structure instead of refitting it; with the shader picking among the voxel levels, only a plant's change between triangles and voxels would. The whole top-level structure's pass is 0.10 ms of the moving forest's frame, with voxels or without: there is nothing to save.

**Cost** on an M1 Max with Metal's tracer (software ray tracing), the default shot (cascades, 3× from 640×400, wind 0.4; whole frames, `METALRENDERER_BENCH_SPLIT=0`): 53.3 ms in the wind, 42.2 ms without it, against 46.0 ms on the custom tracer before it was removed and 27.2 ms for the plants baked and still. The wind's pass, posing the variants and refitting the 232 the plants name, is about 11.6 ms of the GPU's frame. The M4 Max has not been measured since.

Since then (M1 Max, `METALRENDERER_BENCH=forest`, 960×600 and 3× from 640×400, whole frames, fastest of 2 alternating rounds against the build before):

| Setting | Before | Now | What did it |
|---|---|---|---|
| forest static (paused, wind 0.4) | 83.0 ms | 74.7 ms | nothing posed, written or refitted while time stands still |
| forest closeup (paused) | 91.6 ms | 84.3 ms | the same |
| forest 10k trees (paused) | 131.3 ms | 125.3 ms | the same |
| forest moving | 83.1 ms | 77.7 ms | the sway reach (40 m), two refits to an encoder |
| forest moving 3x | 52.9 ms | 45.9 ms | the same |

* The wind's pass is 6.2 ms with a 40 m reach, 1.7 ms with 20 m (moving 3x: 41.7 ms a frame) and 0.6 ms with 10 m; posing every variant's parts is 0.08 ms of it, the rest is the refits. Two refits to an encoder alone are 3% of the moving frame.
* The default reach is now 20 m: the moving forest takes 77.3 ms a frame against 79.5 ms at 40 m, and 44.3 against 47.5 ms at 3x (fastest of 2 alternating rounds).
* With the reach, a plant's boughs stand at rest beyond it: from the air every crown does, and only whole trees lean. The pictures differ from before where those boughs were posed.
* The plants' structures that never change (the leafy meshes' prefixes, the variants at rest, a still scene's one set of variants) are compacted.

Before, on an M4 Max, the forest moving, 640×400 upscaled to 1920×1200 (`METALRENDERER_BENCH=forest`, "forest moving 3x"), whole frame and the trace pass; every row but the last on the custom tracer:

| | Frame | Trace |
|---|---|---|
| Custom tracer, wind 0.4 (the default) | 12.8 ms | 6.6 ms |
| Wind off | 11.1 ms | 5.4 ms |
| Autumn (season 0.8) | 14.4 ms | 7.5 ms |
| Voxels off (`lod=0`) | 13.1 ms | 6.7 ms |
| Leaves as cards | 14.6 ms | 7.6 ms |
| Plants as plain meshes (`baked=1`), still | 10.0 ms | 4.5 ms |
| Metal's tracer (hardware ray tracing), plain meshes, still | 3.1 ms | 0.7 ms |

* On that Mac, Metal's hardware ray tracing was three times as fast on the baked forest as the custom tracer. How it does with the assemblies, their wind and leaf fall there is still to be measured.
* The valley costs 2.5 ms a frame with its 16 generated trees, up from 1.9 ms with the box-and-sphere placeholders (2.4 ms with the wind off).

**Checks** (`METALRENDERER_BENCH=forestcheck`; the four below were run on the custom tracer):
* The forest as assemblies and as baked meshes, with opaque leaves, from the clearing and from above: the same mean brightness (79.4 against 79.3, 72.8 against 72.8 of 255), and single pixels differing on thin geometry (1–3% of them by more than 8 levels).
* Leaves against the sun, each GI method against a 512-frame path-traced reference: means within 1% (71.3 for the reference; 70.9 path traced, 71.2 cascades, 70.6 ReSTIR GI).
* The LOD level view from above: triangles blue, the three voxel levels green, orange and red.
* Scenes without plants render bit-identical to before the plants were added (Cornell, stress, market, gallery).
* On Metal's tracer (M1 Max, 960×600) the mode's assemblies take 69.8 ms a frame (65.6 on the custom tracer) and its leaf cards 223 ms (83): every card triangle a ray meets is handed back to the shader for its alpha test. Its `baked voxels aerial` and `baked lod view` settings show far baked plants as voxels.

**Loading** (from the launch to the scene ready to draw; `swift build` is the unoptimised build Xcode's Run uses):

| | Unoptimised, before | Unoptimised | Optimised |
|---|---|---|---|
| Forest, custom tracer (since removed) | 9.9 s | 0.9 s | 0.17 s |
| Forest, Metal's tracer | 4.7 s | 1.25 s | 0.2 s |

* An optimised build never needed help: the whole forest is made in 0.1 s. An unoptimised one runs the same loops 30 to 100 times slower, and three things took nearly all of its time.
* **The plants' voxels are cached** (`SectionFile.swift`, `GeneratedCache`), and so were the custom tracer's trees of the meshes: 6.5 s to build both, 0.35 s to read. A file is named by a hash of the geometry it was built from (SHA-256, which the hardware does: tens of megabytes in milliseconds in any build), so changed geometry is another file and none is ever stale. (The trees were cached in unoptimised builds only: see below.)
* **A generated texture is named by what it is drawn from** (its generator's version and the seed), not by its pixels, and is drawn only when the texture cache doesn't have its mip chain: the forest's ground map took 1.7 s. `FoliageTextures.version` is the name's version; a test holds each texture's hash and fails when a pattern changes without it.
* **What takes a loop over a plant's vertices is done for all plants at once**, on every core (`Scene.Flora`): the parts' boxes of an assembly (1.1 s) and the baking into plain meshes (2.6 s).
* The cache's files are arrays of the structures the renderer uses, each at a page boundary behind a table of sections: nothing is parsed, and a file of another format, for another key or cut short is a miss. Reading one copies its arrays; it saves no memory.

**What didn't help:**
* **Caching the custom tracer's trees in an optimised build.** It built a city's trees (5.3 million triangles) in 0.13 s, and takes 0.15 s to hash the meshes and copy the trees out of their 420 MB file. The forest gains 55 ms, the city nothing: not worth the disk.
* **A file of the plant library** (meshes, parts, bones). Planned, and not needed: the library takes 17 ms unoptimised; what was slow was done per plant on one core.
* **Leaf cards.** They store fewer triangles (the forest's 24 boughs lose 9,900 of theirs) and were 13% slower on the custom tracer (14.6 against 12.9 ms); on Metal's, in software, 2.7 times as slow (above). A ray visits as many nodes and tests more triangles (13 against 9 per ray), because a card's box covers the whole twig, and each candidate hit reads the mask. One card per twig instead of two crossed was no faster. They are kept as an option.
* **A 64-voxel grid.** Marching 64 steps costs more than tracing the plant's triangles, so a finer level would only ever be slower. 32 it is.
* **Committing a voxel hit to Metal's ray query** (`commit_bounding_box_intersection`), so that the traversal skips what is behind it. The commit costs far more than the boxes it saves: on an M4 Max the open world's road views took 25–30 ms a frame with it and 9–12 ms without, the forest 5.6–13.8 ms against 4.7–9.6 ms. The shader keeps the nearest voxel hit and compares it with the query's triangle at the end. The forest's pictures are the same bit for bit.
* **Padding the parts' boxes for the strongest wind** (the custom tracer). It cost 0.3 ms with no wind at all. The boxes are padded by the current strength, and the assemblies' nodes refitted when it changes.
* **Keeping the leaf-fall limit in a register across the traversal loop** (the custom tracer). 0.7 ms a frame in the wind; it is computed where a leaf is tested.
* **Posing only the variants plants name.** plantWindKernel poses all of them in 0.08 ms; the refits are the cost.
* **Three or more refits to an encoder** crash the M1 Max's driver (SIGBUS), as four did before.

**Limitations:**
* The open world's plants stand still: they are in instance blocks, whose scene is still (its structure built once), so there is no wind there, and a change of season makes the scene again.
* Plants of the same phase bucket swing their boughs together (each still leans on its own); a plant's share of leaves is one of five steps.
* The wind refits every variant a plant within the sway reach names: on the M1 Max (Metal 3, two to an encoder) that is 2% of the moving forest's frame at 20 m (8% at 40 m).
* Swaying ground cover is left to the rays by the raster visibility buffer: it leans where the rays meet it.
* A plant traced as voxels only leans with the wind; its boughs don't move. Far trunks are as grainy as far crowns.
* Dead trees only lean. A patch of grass leans as one.
* The ground's colour map has a texel every 31 cm.

### Animated characters

The **Crowd** scene fills a square with the characters in `Assets/Characters`: every `.fbx` file there is a character, and every `.fbx` in `Assets/Characters/Animations` is a clip all of them can play. The repository's are Mixamo's X Bot and Y Bot with two idles, a walk and a run. Rows of characters walk and run along lanes at their clip's own speed, and others stand around.

* **Poses are animated, not characters.** Everything here is ray traced, so a deformed mesh is not something a vertex shader does to an instance: it needs vertices of its own and an acceleration structure around them. The crowd keeps a pool of *pose slots* (`Crowd.swift`). A slot is one character playing one clip, or a cross-fade of two, from some point of its loop. Each frame the GPU animates every slot once, and every character in the square is an ordinary instance of one slot's mesh. A frame's cost follows the number of slots, not of characters: 131072 characters on 64 slots cost what 64 poses cost, plus a larger top-level tree. Characters on the same slot move in step, which a few dozen slots per clip hide well; a character that must move on its own takes a slot to itself.
* **A frame's work, all in compute** (`Shaders/Crowd.metal`, `CrowdSkinner.swift`):
  * `crowdPoseKernel`, one thread per joint and slot: the joint's skinning matrix. The thread walks up from its joint to the root (a skeleton is about a dozen joints deep), blending each rotation between two keys of the clip and, in a cross-fade, between the two clips.
  * `crowdSkinKernel`, one thread per vertex and slot: linear blend skinning of up to four joints, into the slot's range of the scene's position and normal buffers. Hits then read a pose's vertices like any mesh's (`MeshData.vertexOffset`).
  * Metal refits the slots' bottom-level structures: a pose keeps its triangles, so its structure keeps its shape and only the boxes move. Only one is built per character, and every other pose takes that tree, refitted into a structure of its own. (The custom tracer, since removed, refitted its own trees in a kernel, `crowdRefitKernel`.)
  * Then the top-level structure, as for any moving instance.
* **Motion vectors.** The skinning keeps each slot's previous positions, and a hit on a deforming mesh interpolates them for the point's previous position (`MeshData.prevOffset`). The denoisers, the upscalers and the reuse passes then reproject limbs the way they reproject moving objects. Without it they throw a moving limb's history away, and limbs come out at traced resolution. Both offsets are compiled in only for a scene that has a crowd (`DEFORMING_MESHES`, with the scene's light types): read at every hit of every scene, they cost the trace 7% in the stress hall; now the other scenes trace the code they always did and render the same images, bit for bit.
* **Import** (`FBXReader.swift`, `SkinnedCharacter.swift`): a reader of binary FBX written for this, with no dependencies.
  * The file is memory-mapped and never copied. A node is a 24-byte record of offsets, names are compared as bytes, and what isn't wanted is stepped over by its end offset: a clip file carries a whole copy of its character's mesh that is never touched.
  * Arrays are inflated once, when asked for, straight into the Swift array they become, on all cores. The six files are read at the same time.
  * The skeleton is matched by joint name (the files list the joints in different orders). Clips are retargeted to each character by its joints' rotations away from the bind pose, so X Bot, whose joint axes and bone lengths differ from Y Bot's, plays Y Bot's clips. A clip's travel is taken out and kept as its speed.
  * Coarser levels of the mesh come from `MeshSimplifier`, whose collapses keep a subset of the vertices, so skin weights carry over.
  * On this M1 Max the six files (12.6 MB) are read in 26 ms and retargeted in 2 ms; the levels of detail take 320 ms. All of it is then kept in one cache file, which loads in 3 ms.
* **What it costs** (`METALRENDERER_BENCH=crowd`: M1 Max, 640×400 upscaled 3×, cascades GI, 2048 characters, 64 poses and detail level 3 unless the row says otherwise, the animation running; ms):

  | Custom tracer (since removed) | skin | blas | tlas | trace | frame (Metal 3) | frame (Metal 4) |
  |---|---|---|---|---|---|---|
  | 8 poses | 0.04 | 0.26 | 0.35 | 3.24 | 8.5 | 7.4 |
  | 64 poses | 0.43 | 1.23 | 0.14 | 3.46 | 10.8 | 8.4 |
  | 256 poses | 1.02 | 4.57 | 0.14 | 3.55 | 15.5 | 10.8 |
  | 256 characters | 0.45 | 1.21 | 0.07 | 2.39 | 9.1 | 6.9 |
  | 32768 characters | 0.42 | 1.25 | 0.47 | 5.05 | 13.6 | 11.1 |
  | 131072 characters | 0.29 | 0.96 | 1.07 | 5.26 | 13.9 | 12.8 |
  | 32 poses, full detail | 0.86 | 4.90 | 0.13 | 3.59 | 15.6 | 10.7 |

  * The pass columns are Metal 3's. A benchmark times each pass in its own command buffer, which costs the small passes a few tenths of a millisecond there: under Metal 4 the same 64 poses take 0.14 ms to skin and 0.68 ms to refit, and both grow in step with the pose count.
  * A pose's cost is its triangles: the refit is what a level of detail buys back (4.9 ms for 32 poses at full detail, 0.9 ms at level 3).
  * The CPU's share is 0.3 ms up to a few thousand characters, 1.1 ms at 32768 and 3.5 ms at 131072: a walker's transform is still written by the CPU every frame.
  * **Metal's refits**, the only ones now, cost about 0.09 ms per structure on this GPU, whatever its size: 6.3 ms for 64 poses and 23 ms for 256, against the custom tracer's 1.2 and 4.6 ms above. Use fewer poses.
* **Checked** by `METALRENDERER_CROWD_CHECK=1` in every setting of the mode, under both APIs: the GPU's vertices are within 3 µm of the CPU's (and on the custom tracer, when it was there, no refitted triangle, box or bound was off). Metal 3 and Metal 4 render the same images.
* **The same picture every run.** A shadow ray stops at the first occluder its tree has, and the shadow filter takes that one's distance for the penumbra (`isVisibleBlocker`). Metal builds a pose's tree a little differently from run to run (these meshes, not the other scenes'; more often the more of them it builds, or with the GPU busy). With a tree built per pose the crowd on Metal's tracer came out as one of two pictures at 64 poses (31 pixels in penumbrae, up to 4 levels apart) and as a different one almost every run at 512. Now a character's first pose is built and the others are refits of it, so every pose has its triangles in the same order and only 2 builds are left to vary: the picture was the same in every run tried (16 each at 64 and at 512 poses, on an idle GPU and with three renderers at once, Metal 3 and Metal 4), frame times are within noise of before, and 512 poses load in 0.13 s instead of 0.18 s.
  * Didn't help: building the poses one command buffer at a time (one picture at 64 poses on an idle GPU; not at 512, nor with the GPU busy), an encoder or an unwaited command buffer per build, compacting them, a jitter of the vertices they are built from.
  * Shadow rays that take the closest hit also give one picture, whatever the trees: 0.05 to 0.13 ms a frame on an M4 Max.
* **Limits:**
  * Under Metal 4 the crowd needs a GPU with Metal 4 ray tracing (M3 and later): its refit is written the same way, through the Metal 3 queue, but has not been run.
  * A character has one material, so the bots' two colours (body and joints) are one tint each.
  * A walking row shares one motion and one size, so its members keep their distances; nothing steers around anything.
  * Cross-fades keep two clips at the same point of their loops, which is right for clips that start on the same foot.

### Procedural city

The **City** and **City at night** scenes are generated: a seeded street grid of 1 to 100 blocks, and on every lot a building of its own (`CityPlan.swift`, `Building*.swift`, `Scene+City.swift`). Nothing is loaded; the same settings always build the same city.

* **The plan** (`CityPlan`): block sizes are jittered and the middle roads are avenues. A block's district decides its style: office towers in the middle, modern mid-rise and brick apartment blocks around them, old-town houses and warehouses at the edge, and one block near the middle is a park. Houses and apartment blocks stand shoulder to shoulder around their block with a courtyard behind; towers and warehouses stand free. Each lot knows what its four sides look onto (a street, open ground, a neighbour's wall).
* **A building** (`BuildingGenerator`) is made from its lot, style, height and seed:
  * **The plan and massing:** a rectangle, or an L, U, T or courtyard ring; towers stand on a podium and step in on their way up, and a mid-rise's top floor can stand back behind a terrace.
  * **The facades** are a split grammar: storeys, then a pier at each end and equal bays, then a tile per bay. Tiles: a recessed window (wall cut around it, reveals, frame with mullions and transom, sill, lintel, shutters), a glazed door onto a balcony (bars, a glass balustrade or a solid one), the front door with its step, a shop window under a sign and an awning, a warehouse's loading door. Ledges and the cornice run around the building, mitred at its corners. Party walls are blank.
  * **The tops:** a flat roof with a parapet and things on it (the stair's head, air handlers, a water tank, a mast), or a gabled, hipped or mansard roof (with dormers), chimneys through it. An L's two gabled roofs meet in a valley.
  * **Five styles** (old town, residential, warehouse, office, modern), each a set of ranges and palettes that a building draws from, so two of a style are related, not alike.
  * Nothing is laid flat on anything else, because coplanar faces show as noise when ray traced: walls are cut around their openings, and what projects is a box without its back.
* **Windows are real.** Every window has a pane of glass (see "Glass" below) in a frame, and behind it either a blind (drawn all the way, part of the way or not at all) or a room: a box with a floor, walls, a ceiling and a piece of furniture, half the building's depth at most. Shops are rooms with a counter and shelves. `rooms` sets the share.
* **At night** a share of the windows (`lit`) have a light on: the blind glows, or the room's ceiling lamp is on and its light falls through the glass onto the street. A building's lit blinds are one emissive mesh and its lamps another, so it is two mesh lights however many windows it has; a block's street lamps are one more. The scene asks for the light table whatever its light count (ReSTIR DI lights it, as in the Night market).
* **Meshes of several materials.** A building's walls, trim, frames, roof and rooms are one mesh: each triangle carries an offset to add to its instance's material index (`Scene.addMesh(_:uvs:materials:)`, `SceneShading.triangleMaterials`, compiled in only for scenes that use it). With a mesh per material, a ray that met a building walked a dozen trees with the same bounding box: the street view took 15.4 ms instead of 8.4.
* **Generated textures** (`ProceduralTextures.swift`): brick, plaster, concrete, roof tiles, asphalt, paving and metal panels, each a tiling base-colour map and normal map (the metal a roughness map too), 512 or 1024 pixels, made on all cores in 0.2 s the first time and kept as PNGs in `~/Library/Caches/MetalRenderer/textures`. They are near white: a building's own colour tints them, and UVs are in metres, so bricks are the same size on every wall. They go through the texture streamer like a model's. `textures=0` builds the city in flat colours.
* **Detail has a limit.** A building is kept under 60k triangles: a big one's upper storeys get windows without frames and sills, and a tall tower's get one ribbon of glass per wall.
* **Windows as modules** (`modules`, off by default). A window's shell (the sides of its hole, its frame, sill, lintel and shutters) is made once and placed at every window like it (`Building.Module`): its vertices and texture coordinates are its own corner's, snapped to 0.1 mm, so the same window anywhere is the same triangles, and the city keeps one mesh for each. A building is then an assembly of them and of its own mesh (its walls, roofs, blinds and rooms), as a plant is of its boughs, but rigid (`Scene.Assembly.rigid`): one variant, no wind, no leaves, no voxels, and the shaders walk its parts without the plants' code (`RIGID_ASSEMBLIES`, bit 19 of the features: three-level queries, `ASSEMBLIES`). A triangle's material is its slot's, so a module is the same mesh in every building whatever its colours. Its glass and its lights are instances of their own, as before.
  * 4 × 4 blocks: 364,000 triangles of the buildings' own and 353 modules of 23,000 placed 5,380 times, against 677,000; the BLASes 17.6 MB and the buildings' variants 1.6 MB, against 30.2 MB. The pictures are the same but for noise (RMS under 0.9 levels), and Metal 4 draws what Metal 3 does.
  * But on Metal's tracer the frames are slower (M4 Max, hardware ray tracing, medians of 3 alternating rounds, `modules=0` against `modules=1`): 2.85 → 3.09 ms from above, 3.21 → 3.55 from the street, 3.43 → 3.90 at the facade, 6.91 → 8.43 at night, 3.03 → 5.83 at 10 × 10 blocks. The glass and the cascades' rays take 21–140% longer: every building's ray goes down a third level, into a structure of its parts, whose boxes all lie inside the building's. (The custom tracer, since removed, measured the same on an M1 Max: 12–16% slower.) So it is a way to halve a city's memory, not to speed it up.
  * With raster primary visibility or virtual shadow maps, a building of modules is traced, as a plant is (the raster draws its box): those paths can't draw assemblies.
* **What it cost** (`METALRENDERER_BENCH=city`: M1 Max, 640×400 upscaled 3×, cascades GI, the custom tracer, since removed; ms):

  | | buildings | triangles | built in | trace | glass | reflections | ReSTIR | frame |
  |---|---|---|---|---|---|---|---|---|
  | 1 × 1 blocks | 10 | 0.07M | 5 ms | 0.82 | 0.48 | 0.48 | | 4.9 |
  | 4 × 4 (default), from above | 99 | 0.68M | 0.07 s | 1.22 | 0.88 | 0.77 | | 6.4 |
  | 4 × 4, from the road | | | | 1.82 | 1.85 | 1.18 | | 9.2 |
  | 6 × 6 | 309 | 1.8M | 0.2 s | 1.47 | 0.97 | 1.01 | | 7.1 |
  | 10 × 10 | 868 | 5.3M | 0.5 s | 1.66 | 1.09 | 0.77 | | 6.8 |
  | night, 4 × 4, from above | | | | 0.63 | 1.12 | 0.81 | 8.9 | 17.3 |
  | night, 4 × 4, from the road | | | | 1.02 | 2.89 | 1.16 | 12.8 | 26.1 |
  | night, 10 × 10 | | | | 0.93 | 1.38 | 0.78 | 9.4 | 19.3 |

  * "Built in" is the generator plus the custom tracer's trees (about half each); 10 × 10 has 75,000 windows, 8,200 of them with rooms.
  * By day the city has one light, the sun, and its frame grows slowly with its size: rays walk one tree per building.
  * At night it is 192 mesh lights of 8,900 triangles (1,706 and 58,000 at 10 × 10), and ReSTIR DI is most of the frame, as in the Night market.
  * On Metal's tracer, the only one now, 10 × 10 is 1,737 structures, 485 MB after compaction, 6.6 ms a frame, and Metal 4 draws the same images as Metal 3 (but see the limits).
* **Checked** by `CityTests`, `BuildingTests`, `PlantTracingTests` and `ProceduralTextureTests`: the plan's lots stand inside their blocks and apart; every style's meshes are valid over many seeds and lots (finite, unit normals, no triangle without area or, where textured, without UV area, inside the lot, under the limit); a building of modules is the whole building's triangles, slot by slot, and shares its windows' shells; a flat building has fewer triangles and as many windows; a city of modules is still, has rigid assemblies of one variant each and doesn't compile the plants' code; outlines close around their plans; a seed always builds the same city; the textures tile.
* **Limits:** every building is unique but for its windows' shells (modules), so memory and load time grow with the city; the street grid is a grid; rooms are boxes; there is no night in the day cycle (the sun stays 12 degrees or more above the horizon, and the night scene is its own).

### Open world

The **Open world** scene has no edge: hills, woods, open country and cities, all of it a function of the seed and the place (`World.swift`). Nothing is stored that can't be made again, so the world is made a tile at a time around the camera and forgotten behind it.

**The world.**
* **Ground:** broad hills (2 km across, up to 90 m) with the Forest's rolling ground on top. Places are doubles, and the noise finds its lattice cell exactly however far out it is, so 50 km from the origin is as exact as the origin.
* **Cities:** at most one to a 4 km cell (the cell at the origin always has one), a disc of 300 to 900 m on ground levelled to its middle's height, with 300 m more for the hills to come back. Its streets are a grid in the world's axes, 84 by 68 m from block to block. A block is made from the seed and its place in the grid alone: its district by how far out it is, its lots, lamps and trees (`CityPlan(block:)`), its buildings by the City's generator.
* **A city's ground:** a block is built where all of it is inside the city's radius, and a 12 m street lies along every side of a built block, and the streets meet in a junction at each of its corners (`World.roads`): so the city ends at its last street, in a stepped outline, and the country begins there. The streets are sheets of asphalt 2 cm over the ground, with a broken line down the middle; where three or four streets meet, each has a zebra crossing and a stop line across the lane of the cars that come to the junction (they keep to the right). A block is paving inside a kerb of stone, with a lawn and a few trees in its courtyard where its houses stand around one.
* **Fields:** the belt of open ground around a city is fields, 30 m wide here and 250 m there (a noise decides), so the woods come up to the city in places. A field is a meadow, wheat, a green crop or ploughed earth, one or two to a cell of 128 by 96 m in the city's axes; the sown ones have their rows (a texture). Their sides are multiples of 16 m from the city's middle, which is one itself: they lie on the ground's cells at every level, so a field is the same field from 2 km as from its edge.
* **Roads between cities** (`World.Highway`): a road joins a city to the city of each of the four cells next to its own, where there is one.
  * **Where it runs.** It leaves a city by the end of the street through the city's middle, which makes that street's last junction one of four ways, and comes into the other city the same way. It is straight on at both ends and swings over from the one city's line to the other's between them, so it is a graph over its axis: one place across for each place along, and how far a place is from the road is a few multiplications. It stays between its two cities, inside their two cells. In 60 worlds (1,602 roads, 0.9 to 7 km long) no road comes within 670 m of another, away from the city the two share.
  * **How high it is.** The road lies on the broadest of the hills alone (the two widest of the hills' four waves), and leaves a city on the city's level, coming to its own over 700 m. So it is less steep than the country it crosses: the steepest stretch of the median road climbs 7%, that of nine roads in ten less than 11%, and the steepest of all 19% (where a city stands high over the country around it).
  * **The ground beside it.** Within 10 m of the road's middle the ground is the road's own, level across; beyond that it comes back to the country's over a bank 36 m wide, or 2.5 times what the road is over or under the country there (120 m at most). So the road goes through a hill in a cutting and over a valley on an embankment, and both are slopes of grass. The 10 m are meadow; trees stand on the banks but not within 11 m of the road's middle, and grass grows up to a metre from the asphalt. A road's heights and bank widths, one of each every 16 m, are worked out once and kept with the `World`.
  * **Its asphalt** is 8 m wide (12 m where it leaves a city, narrowing over 24 m), in pieces of 8 m along the road's axis, each cut at the tile's sides: a tile has the part of the road that is in it, at every level. At levels 0 and 1 the ground's cells under the asphalt are the road's own planes (its heights change on the lines of the coarsest cells, and the 10 m of level ground cover the 4 m cells that reach under the asphalt), so a piece lies flat, 2 cm over the ground, with a line along each edge and a broken one down the middle. At level 2 the cells are 16 m, wider than the level ground: there a piece is cut along the cells' triangles too, and each part lies on its triangle. The first 12 m from the city's junction are a street's, with its zebra crossing and its stop line.
  * **Checked** (`METALRENDERER_BENCH=worldroads`): its ten pictures are bit-identical with a cold cache and a warm one, and on Metal 3 and Metal 4 (on the custom tracer, then the default); without the cache the nine stills are, and the flight differs by an RMS of 0.2 levels (its scenes come a few frames later). The two tracers' means agree within 2%. A tile a road runs straight across has 256 more triangles at levels 0 and 1 and 144 more at level 2; the 289 tiles around the first city are made in the time they were, and the views of `world` and `worldground` cost what they did. Every other scene's pictures are the bytes they were.
* **Checked** (`METALRENDERER_BENCH=worldground`): its eight pictures are bit-identical with a cold cache, a warm one and none, and on Metal 3 and Metal 4 (on the custom tracer, then the default); the two tracers' means agree within 1.5% (within 0.1% in the views of the streets; the ones with woods in them differ as the tracers' trees do). The roads, the paint and the kerbs are 0.4% more triangles in the nine tiles around the camera; the tiles are made in the time they were, and the day's and the night's views cost what they did.
* **Woods:** one candidate tree to each cell of a 4 m grid over the whole world, from random numbers of that cell's own, so asking for another piece of the world moves no tree. Woods and open country alternate over half a kilometre; conifers stand higher and on slopes, oaks low, birches at the woods' edge. Bushes and ferns grow in patches under the trees and grass in the open, up to a city's last street; none on a road, and none in a sown field. No tree stands in a city's fields, or beside a road between cities.

**Tiles** (`WorldTile.swift`) are 256 m squares at three levels of detail: the camera's tile and its eight neighbours whole (ground cells of 1 m, buildings with their glass and their rooms), the tiles to about 1 km with 4 m cells and buildings without glass, made flat (`BuildingSpec.Detail.flat`: what stands out of their walls as its front faces alone, their rooms dark unless lit; 6.56 → 6.50 million triangles around the first city, its BLASes 294 → 291 MB, the far views within RMS 3.1 levels and their means within 0.14%), the rest to 2.2 km with 16 m cells and a box for each building. A city's roads are in the tile of the middle of their cell of the grid, at every level; their paint is left out at the last, and the kerbs are a level-0 tile's. A road between cities is cut at the tiles' sides, and lies on each tile's own ground. Trees are placements at every level (which plant of the library, where, how turned): the far ones are the voxels the plants already have. A tile's ground has a skirt down its sides, which hides the step to a neighbour of another level; neighbours of the same level share their edge's heights and normals exactly, because both ask the same function at the same places.

A tile is a file once made (`~/Library/Caches/MetalRenderer/generated/world-<seed>-v<version>/<level>/<x>_<z>.tile`, a section file: its meshes' arrays, its materials, its trees: the plants standing on it), keyed by the world's settings and versions. A city's tile is keyed by the share of its windows that are lit as well, and has its lights (see "The day and the night" below); the country's is the same whatever that share is. A file written for the custom tracer also has the tree over each of its meshes; nothing reads those now. The files count against the cache's cap like the rest of that folder (`METALRENDERER_CACHE_MB`): a tile read is marked as used, and the first one written in a launch starts the sweep of the files used longest ago (before, only an unoptimised build's caches started it).

**The scene** (`Scene+World.swift`) is one moment of the world: the 289 tiles around the camera's. When the camera is a quarter of a tile into another one, the renderer makes the scene around that one in the background (the tiles the two share are kept, the new ones come from their files or are made) and swaps it in; what the frames have gathered (the upscaler's and the denoisers' histories) holds, since the world is in the same place. The scene's own instances are the tiles' chunks and the ground cover; a tile's trees are a group of instances with a name (`Scene.InstanceGroup`), which the scene only makes if the renderer doesn't have it.

**A tile crossing costs no frame.** Everything of the next scene is made off the main thread, and the swap between two frames takes 0.1 ms:
* **The scene's buffers and structures are made where the scene is** (`SceneBuffers.swift`): geometry, instance records and the acceleration structures, built on a command queue of their own (the frames' queue runs its command buffers in order, and a frame would wait behind a build).
* **A mesh keeps its structure from scene to scene.** A tile's chunk or a plant of the library is the same triangles in every scene that has it, and says so by a name (`Scene.meshNames`); Metal's per-mesh structure of a named mesh is handed to the next scene. A crossing builds the 43 meshes that are new (100 MB as built, 50 compacted) instead of all 370 (760 MB).
* **And its buffer.** Such a mesh is in a buffer of its own (`MeshBlock` in `SceneBuffers.swift`): its positions, normals, UVs, indices and its triangles' materials one after the other. The next scene takes the blocks of the scene being drawn by their names and fills only the new ones, and a block goes when the last scene that has it does. A hit finds a mesh's vertices through an address in the mesh table (`MeshData.block`), compiled in only for a scene with such meshes (`STREAMED`, with the scene's light types): the other scenes trace the code they did and render the same images, bit for bit, and so does the world with safe math (`METALRENDERER_MATH=safe`; with fast math the other code rounds differently: 0.11 levels RMS).
* **And a tile's trees stay as they are.** They are the same instances in every scene that has the tile, at any level of detail, for as long as the scene's origin stays; the renderer keeps what it made of a group in a block (`InstanceBlock` in `SceneBuffers.swift`), and a crossing makes the blocks of the 17 tiles that are new: 22,000 trees of 360,000. (Every plant of the library is added to a scene first, in the library's order, so a block's records name the same meshes and materials in the next scene.) The scene keeps one structure over all its instances, so what a block holds is its part of that: the block's records in a buffer of its own, and its instances' descriptors. The next scene copies its blocks' descriptors into one buffer (52 MB) and builds its structure over them, in the background as before. A descriptor carries its instance's id (the block's number and the instance's place in the block), a hit returns it (`user_instance_id`) and finds the record through a table of the blocks' buffers (`TILED`, compiled in for such a scene only). An id is the same in every scene, so what goes by it (which leaves let the light through) no longer changes at a crossing. (The custom tracer, until it was removed, kept a tree per block, and the tiles' files carried the trees over their meshes: the rows and notes below that name it.)
* **Nothing in the world moves**, so its instances are written once and Metal's structure over them is built once, in the background, for tracing rather than for a fast build and refits. That goes for every scene in which nothing moves (`Scene.isStill`): the Forest (its plants baked, as they were on Metal's tracer then), the City and the Valley traced 9 to 13% faster for it (3.02 → 2.68, 2.03 → 1.85 and 1.77 → 1.54 ms), the world 30 to 35% (5.4 → 3.7 ms from the start). Their pictures differed from before in the pixels where two surfaces coincide (another tree picks the other one: at most 0.15 levels RMS, fewer than one pixel in ten thousand more than 8 levels off).
* **The textures stay as they are streamed**: every scene of a world has the same textures in the same order, and takes the streamer and what it has mapped from the scene before. (A new streamer's first frame spent 25 ms in the kernel mapping its tiles.)
* **The buffers are used once before the swap** (a copy of a few bytes from each, on the build queue): the first command buffer to name a buffer pays for bringing it into the GPU's memory map, 5 to 12 ms for these, and that would be a frame.
* **The replaced scene is let go of on another thread**: freeing its buffers and arrays took 13 ms.

**Memory.** A scene borrows its tiles' meshes instead of copying them (`Scene.BorrowedMesh`): a tile's arrays are its file's pages, mapped, and the renderer copies them from there straight into the mesh's block, once. The plants' baked meshes are lent the same way by the library, which is kept from scene to scene. So at a crossing only the new tiles are added to what the GPU holds, and the peak is the scene, the new tiles and a second structure over the instances; before the tiles had buffers of their own it was two whole scenes. The scene itself no longer has an array of its trees: 0.3 GB less at any time. Under Metal 4 the residency set lets go of a replaced scene's buffers eight frames after the swap, not 600: it held every scene of the flight below, 14.9 GB at the peak against Metal 3's 8.1.

Measured on an M4 Max, a flight of 60 m/s across two tile crossings (`METALRENDERER_BENCH=world METALRENDERER_BENCH_ONLY="flight 3x"`, medians of three runs; the benchmark loads the world's next scene as the app does):

| | The swap, on the main thread | The longest frame | Made in the background | Memory at the end | Peak |
|---|---|---|---|---|---|
| Metal's tracer, Metal 3, at first | 184 ms | 201 ms | 200 ms | 7.7 GB | 8.1 GB |
| ...the scene made in the background | 0.1 ms | 17 ms | 163 ms | 3.2 GB | 4.4 GB |
| ...and the tiles in buffers of their own | 0.1 ms | 20 ms | 140 ms | 3.2 GB | 3.9 GB |
| ...and their trees in blocks (now) | 0.1 ms | 22 ms | 74 ms | 2.9 GB | 3.4 GB |
| Metal's tracer, Metal 4, at first | 202 ms | 222 ms | 214 ms | | 14.9 GB |
| ...the scene made in the background | 0.1 ms | 18 ms | 164 ms | 3.2 GB | 4.5 GB |
| ...and the tiles in buffers of their own | 0.1 ms | 20 ms | 140 ms | 3.2 GB | 3.9 GB |
| ...and their trees in blocks (now) | 0.1 ms | 20 ms | 72 ms | 2.9 GB | 3.5 GB |
| Custom tracer (since removed), at first | 34 ms | 54 ms | 509 ms | | 8.2 GB |
| ...the scene made in the background | 0.1 ms | 20 ms | 382 ms | 3.6 GB | 5.0 GB |
| ...and the tiles in buffers of their own | 0.1 ms | 11 ms | 236 ms | 2.6 GB | 3.2 GB |
| ...and their trees in blocks | 0.1 ms | 11 ms | 182 ms | 2.3 GB | 2.9 GB |
| ...and the tiles' own trees in their files (now) | 0.1 ms | 11 ms | 65 ms | 2.0 GB | 2.5 GB |

* Memory is the process's footprint (`footprint`, and `/usr/bin/time -l` for the peak). On Metal's tracer at the end: the scene's geometry 0.64 GB, its instances 0.19 GB, its structures 0.56 GB, the renderer's own targets 1 GB, and 0.3 GB of the process's arrays.
* **The rest of those arrays is memory the system's allocator holds on to.** A large array that is freed stays in the footprint until the system wants it back (a gigabyte allocated and freed in a test program was still counted six seconds later). So every array a scene makes and drops counts as if it were kept, and arrays of a new size every time pile up: before the tiles and plants were borrowed and the instances' array rounded to a step, 12 km of flight held 2.7 GB of them; now 0.95 GB, flat.
* The longest frame is one of those drawn while the next scene is being made: its builds share the GPU with the frames.
* Over 12 km at 150 m/s (52 scenes, `METALRENDERER_BENCH=shot METALRENDERER_SCENE=world METALRENDERER_FLIGHT=150,0,20 METALRENDERER_SHOT_FRAMES=4800`) the peak went from 5.1 to 4.4 GB on Metal's tracer under Metal 4 and from 5.1 to 3.3 GB on the custom one with the tiles in buffers of their own, and to 3.6 and 3.0 GB with their trees in blocks; no frame failed on either, with the residency set letting go after 16 frames. With the tiles' own trees in their files the custom tracer's peak is 2.6 GB, and a scene of that flight is made in 61 ms at the median (120 ms the first time over the route, when the files Metal's tracer had written there were given their trees); Metal's tracer is where it was (63 ms, 3.7 GB).
* **What a frame pays for the blocks:** nothing measurable on the GPU (the world's eight benchmark views, four alternating rounds against the build before: within 0.1 ms on both tracers, no view with the same sign in every round on the custom one). The CPU declares the blocks' buffers to every pass that traces, 370 on Metal's tracer and 630 on the custom one: 0.04 ms more a frame (0.07 → 0.11 ms on the custom tracer, whole frames).
* **What a frame pays for the trees' blocks.** On Metal's tracer the eight views are within 0.07 ms of the build before under either API (three alternating rounds; most views change sign from round to round), and the CPU declares 290 buffers more: 0.01 to 0.04 ms a frame. The custom tracer's shaders are the ones it had, and its tree is another: the rays visit 12% fewer top-level nodes over the eight views (a tile's ground and buildings, large boxes, are no longer among its trees low in the tree). From the ground its frame is 0.1 to 1.0 ms shorter (the start 10.2 → 10.0 ms, the woods 13.8 → 12.8), from the air 0.1 to 0.15 ms longer (the flight 8.46 → 8.60; four alternating rounds).
* An unoptimised build (Xcode's Run) makes a scene in 0.3 s on Metal's tracer and swaps it in in 0.2 ms; 1.2 s before the trees were in blocks, and at first 4 s and a stall of 0.2 s. On the custom tracer it took 51 s over the first scene's trees, once, and cached them, a file to a mesh (`tree-<hash of its vertices>.sect`, 0.5 GB for a scene). Now they are in the tiles' files, which either build reads whoever wrote them: with them there, an unoptimised build launches in 6.6 s (8.9 s with the cache of trees) and makes a crossing's scene in 2.2 s (8.8 s), the rest being its slow loops over the instances' trees. A tile it makes itself has its trees built by those loops, as slowly as before.
* **A tile never seen costs the custom tracer what it did.** Over a world with no files yet (another seed, a flight into a city): a scene made in 196 ms at the median against 199, the first scene's tiles and trees in 0.53 s against 0.56, the peak 4.6 GB against 4.8. The crossing that brings in a city's tiles takes 0.41 s against 0.34: a tile's chunks' trees are built one after the other by the thread that makes the tile, where the tracer built all the new meshes' at once. The tiles' files of that flight are 2.6 GB instead of 1.3.
* **Making a tile is 2.4 times as fast** (0.32 → 0.13 s for the 289 around a city, a city tile at level 0 in 70 ms instead of 165), on either tracer: every part added to a tile's mesh reserved room for exactly that part (`reserveCapacity` in the loop), so the arrays were copied whole for each of a city tile's thousands of parts, instead of growing by doubling. It showed when a change to how the file is written made the same loop take twice as long.
* A tile's file is written from the chunks' arrays where they are (`SectionFile.Writer`, a section in parts), not from one array of each kind put together first and then a copy of the whole file: two copies of a tile fewer in memory while it is written, and the peak of a first visit on Metal's tracer is 5.1 GB instead of 5.6.
* **Ruled out:**
  * One buffer for all the tiles with a range for each, which needs no change to the shaders: a buffer counts whole once the GPU has used it (1 GB made and 64 MB of it written: 1.19 GB of footprint after one copy out of it), so the room kept for the next tiles would be memory held all the time.
  * A tile's buffer over its mapped file, with no copy: Metal takes a read-only mapping (`makeBuffer(bytesNoCopy:)`) and reads it right, but its pages count as the process's once the GPU has used them (a 256 MB file: 0.17 GB after a kernel read a part of it, 0.32 GB after a structure was built from it). It would save the copy, 24 ms for a whole scene, and no memory.
  * The trees' addresses in a table that the traversal reads on entering an instance, as virtual geometry's are: 1.6 to 2.4% of the custom tracer's frame. In the instance's record it costs nothing.
  * Buffers Metal doesn't track (`hazardTrackingModeUntracked`): declaring them costs the CPU the same.
  * A structure for each tile's trees under the scene's on Metal's tracer (instancing in two levels, `max_levels<3>`), which would leave a crossing only the new tiles' to build. A test program with 366,000 instances in 289 tiles traced camera, shadow and bounce rays 1.7 to 1.95 times as long through the two levels as through one structure (2.36 → 4.08 ms from the ground, 1.33 → 2.58 ms from 40 m up); the tag alone, on the one structure, cost 13 to 23%. So the one structure stays, and is built again at every crossing: 25 ms of the GPU, in the background.
  * A tree for each tile's trees that the custom traversal enters as it enters an instance (a table of the trees and of their instances' records): a ray makes two more turns of the loop for every tile it passes, and the trace took 15 to 25% longer (the flight: 3.21 → 4.00 ms) though it visited fewer nodes. The tiles' nodes copied into the scene's tree cost a crossing the copying and the trace nothing.
  * The blocks' records in buffers of their own on the custom tracer too, as on Metal's. With the instances' ids in a table for the hit to look up, the cascades' rays took 5 to 8% longer (1.85 → 2.00 ms from the start); with the ids in the traversal's own records, 12 to 18%. The same table costs Metal's tracer nothing measurable.
  * The scene's tree over whole blocks (a ray across the world enters one after the other), over parts of 64 or 256 instances (as few nodes as with 16, and no faster than the one tree was), and with a part counted as its instances when the tree is built (the same tree at the start, a worse one 50 km out: 46 nodes a ray for 42).
  * The new tiles' trees built in a step of their own, every chunk's at the same time, between making the tiles and writing them. The crossing into a city took as long (0.34 to 0.37 s against 0.36), and so it did with a tile's chunks' trees built at the same time inside the tile's making (a loop over every core leaves the loops inside it one core each, so a big chunk's tree is one core's work either way); a first scene, made 64 tiles at a time so that its tiles and trees aren't all in memory before any is in a file, took 0.77 s instead of 0.48.

Measured on an M4 Max (`METALRENDERER_BENCH=world`, `METALRENDERER_WORLD_TEST=1`):

| | |
|---|---|
| A scene around the first city | 289 tiles, 6.4 million triangles, 355,000 trees, 14,000 to 31,000 bushes, ferns and grass patches |
| Making all 289 tiles (first visit) | 0.13 s on every core; a city tile at level 0 takes 70 ms and has 0.4 to 0.8 million triangles |
| A scene around the next tile | see "A tile crossing costs no frame" below |
| A frame in flight, 640×400 → 1920×1200, cascades | 3.8 ms on Metal's tracer (8.1 ms on the custom tracer, since removed) |
| A frame from the start, 960×600 native, cascades | 10.2 ms on the custom tracer |
| A flight of 2.75 km at 150 m/s | twelve scenes, one move of the origin, no failed frame on either tracer or API |

**Range and precision.**
* **The scene's origin follows the camera.** The world's places are doubles and tile numbers; a scene's coordinates are floats from a tile's corner, its origin. Once the scene's middle is 8 tiles (2 km) from that corner, the next scene takes a corner near its middle, the camera is moved by the difference, and the frames' histories start again. No coordinate is beyond 4.3 km, where a float steps by half a millimetre. A scene 50 km out renders as one at the start does; the start rendered with its origin 2.9 km away has the same mean brightness; no pixel of its sky or its city is more than 8 levels off, and 1% of the pixels are, all in its grass and bushes (thin geometry; a float's rounding of where it stands is the likely cause, not checked further).
* **Haze.** The froxel fog ends at 150 m; beyond it the same height fog goes on at 0.4 of its density (`Haze beyond`, above), so the hills fade over 2 km and the horizon is the haze's colour: where the tiles end doesn't show.
* **The sun's light map** (what GI rays take the sun's shadow from) covers 384 m around the camera and follows it in steps of 16 m; what is off the map is in the sun. Camera rays trace their shadow rays as everywhere.
* **Clouds** are where the world has them, not where the scene's origin is: the sky's observer is the camera, and the cloud shadows' square is 4.6 km around it, so that shadows on the ground lie under their clouds wherever the camera goes (by construction; not compared in a picture).
* The fog's noise repeats every 8 m, which divides a tile, so the fog stays as it is when the origin moves. The wind's gusts do not: the plants swing to another phase after a move (every 2 km at the soonest).
* The camera's speed goes to 100 m/s (320 with Shift).

**The day and the night.** The world's day is 240 s (`Heavens`, in `World.swift`), and all of it is there: morning, noon, sunset, dusk, a night under the moon, dawn. The sun goes round as it does at 48° of latitude in late spring: 60° up at noon, under the horizon for four tenths of the day, 24° under it at midnight. It rises over +x and passes over -z. The moon is across the sky from it: up before the sun sets and until after it rises, 37° high at midnight. The clock starts in mid-morning, and `Time of day` moves it: 41% later the sun sets, 60% later it is midnight.
* **One light from the sky.** The scene's sun light is the sun while any of its disc is over the horizon, and the moon after that; the moon's light comes up as the sun sinks from the horizon to 6° under it. So nothing that reads "the sun" changed: the shadow rays, the cloud shadows, GI's light map and the disc the camera sees are the moon's at night.
* **The sky has both.** The atmosphere is lit by that light and by a second source (`SkyParams.glow`): the sun under the horizon, once the moon is the light. The sunset's glow stays in the west as the sun goes down and dies with it (at 18° under, the second march stops), while the moon's sky comes up. The stars come out between 3° and 10° under.
* **The eye adapts, in the lights.** Exposure is fixed, and by its numbers a sunset is a hundredth of noon: dusk would be over as it begins. So the sun's light, on the ground and in the sky, is turned up as it sinks (`Heavens.adaptation`): by 2 at 6.7°, by 8 as it sets, by 128 from 6° under. The moon's light is a twentieth of the sun's, and the night's atmosphere is lit five times as much as that moon would light it, so that the sky lights the ground about as much as the moon does. This is a curve of the sun's height, not a measurement of the picture: the lamps and windows emit what they do in the City at night, and look faint against a sunset and bright at midnight because what is around them changes.
* **A tile is the same by day and by night.** A city's street lamps and its lit windows are in its tiles always, as the City at night's are in that scene: a share of the windows (`lit`) are a lit blind or have a lamp in the room behind them, the lamps' heads are in the tiles to 1 km, and where a building is a box, from 1 km on, its lit windows are moved out along their normals onto the box: a city on the horizon at night is its windows. What emits has a colour as well, which is what it looks like switched off: a lit blind is a drawn blind, a room's lamp a white panel, a far building's windows are its wall. So a tile is made once, and nothing changes shape at dusk.
* **The lights come on by the sun's height** (`World.lightOn`, `Scene.setCityLights`): the street lamps between 2.5° and 0.5°, and each window material at a time of its own between 3° up and 6° under (a building's lit blinds are one material, a chunk's room lamps another: the buildings light up one after the other over the 11 s that takes). Two things change with it. The material's emission, which is where a hit and a sampled light point both take what they emit. And the light table's brightness of the light's triangles (`radianceLum`), which is what a pixel picks its light by: a light that is off is never picked, so it costs the picked ones nothing. The alias table the candidates are drawn from stays as it was built, for the lights' full power.
* **The scene has the lights from 6°.** By day the scene's one light is the sun, nothing samples a tile's lights and the frame costs what it did. From the sun's 6° over the horizon in the evening until it is back there in the morning, the scene is one with the nearer tiles' lights as its mesh lights, lit through the light table (`SceneSettings.worldLit`, the renderer's to set by the clock, as it sets the tile). It is made as at a crossing, in the background, and every tile is kept: 40 ms on either tracer, 3 s before the first window comes on.
* **A tile has its lights in its file.** What emits is not a mesh of its own: a lit blind is a triangle of its tile's chunk like any other, with an emissive material among the chunk's 256. The tile's lights are the triangles of a chunk that have one such material (a building's lit blinds, the rooms' lamps of one colour, the tile's lamp heads): the records the shaders sample, each with its share of the light's power, and the light's power, bounds and mean normal, put together once when the tile is made (`WorldTile.lights`, the same code that makes a scene's own mesh lights). A scene takes them as they are (`Scene.addMeshLight`), so a crossing copies the new tiles' records and builds the light table over them; nothing walks the tiles' triangles again.
* **A mesh light names its material.** A mesh light was an instance with one material; now its record has the material's place from its instance's first (`Light.axis.w`, 0 for every other scene's), which the two places that read a light point's emission add. That is all the shaders needed: a hit on a lit window shades it by its triangle's material as it does any triangle of a chunk.
* **Which lights are sampled:** everything lit in the camera's tile and its eight neighbours, and the street lamps of the tiles to 1 km, so the streets seen from above are lit as far as they have lamps. Further out, and for the windows and rooms of the tiles between, what emits is seen and lights only what a GI ray from there happens to hit. Around the first city that is 300 to 670 mesh lights of 23,000 to 56,000 triangles; in the middle of a city of 889 m (seed 3), 650 to 770 of 100,000.
* **A crossing starts the lights' reuse again.** A pixel's light reservoir names its light by its place in the scene's table, and the next scene's table is another: ReSTIR's temporal reuse and the light picks start from nothing in the first frame of a new scene, where by day they carry over. The upscaler's and the denoisers' histories hold as by day (and so does the sky, which is not drawn again for the next scene).
* **Haze at night.** The fog is on at night as by day, so the far tiles fade into the night's sky as they do into the day's. It is lit by the moon and the sky alone (`Lights scatter in it` is off for this scene): with the lamps and windows in it, a froxel's one light sample a frame scatters in blotches, which is why the City at night has no fog at all. A lamp has no halo for it.
* **Checked:** the 24 pictures of `METALRENDERER_BENCH=worlddusk` are bit-identical on Metal 3 and Metal 4 (custom tracer), the two with the clock running through the change of scene among them, and the two tracers' means agree within 0.4%. The first frame of the scene with the lights is no brighter or darker than the next (`METALRENDERER_SHOT_SWAP=0` against `=1` and `=30`: the means fall by the 0.3 a frame the setting sun takes). A flight of 3 km at 150 m/s while the dusk goes by makes 16 scenes; its longest frame is 18 ms on the custom tracer and 29 ms on Metal 4 with Metal's tracer and a resident's life of 16 frames, and none fails. (The first such flights had one frame of 0.8 and 1.5 s: a scene with other features, glass or mesh lights or neither, needs other pipelines, and the first time ever those are compiled a benchmark waits for the kernels' variants. The app makes them in the background, and Metal keeps them.) Every other scene's picture is bit-identical to the build before.
* **Cost**, on an M4 Max at 640×400 upscaled 3×, the first city from above and from a street: by day 6.9 to 7.7 ms and 5.0 to 5.5 ms on the custom tracer, 3.5 to 3.8 and 2.8 to 3.0 on Metal's with Metal 4, as before (the day's four views and its flight are within 0.2 ms of the build before, and a crossing is its 62 ms). With the lights 12.9 to 13.7 and 10.8 to 11.3 ms, 6.7 to 7.0 and 5.7 on Metal's: every pixel draws its light from the table and traces its shadow rays (ReSTIR DI). Sunset and sunrise are 14.5 to 15.0 and 11.0 to 11.6 ms, 8.5 to 8.8 and 8.3 to 8.7 on Metal's. The change of scene at dusk is made in 31 to 45 ms (111 ms in an unoptimised build) and installed in 0.3 ms.

**Limits** (the open world is not finished):
* A crossing still builds the structure over all the scene's instances, from 52 MB of descriptors copied together (25 ms of the GPU, with two structures held for a moment). Only a structure per tile under the scene's would leave a crossing its new tiles alone, and that costs every frame (see "Ruled out"). The ground cover is made again with every scene. That, the new tiles' meshes and the scene itself (0.01 to 0.02 s) are the 0.07 s above.
* The open world's plants stand still: no wind there (see "Generated plants").
* Lights come on by material: a building's lit blinds together, and all the lit rooms of a chunk. A window that is lit is lit all night.
* While the scene has the lights and the sun is the light, ReSTIR runs for the sun alone; and a sun near the horizon is dear on either path, its shadow rays crossing the whole scene. Sunset and sunrise are the dearest frames of the day.
* The eye's adaptation is a curve, the moon is always full, the stars don't turn, and no cloud is lit from below after the sun has set for the ground.
* At night a street's lamps go on as its tile comes within 1 km, and the windows of the tiles beyond the camera's neighbours light nothing but by GI; ReSTIR draws lights for pixels no light reaches.
* A road joins two cities only if their cells are next to each other: a city with no such neighbour has no road out of it. Roads meet nowhere but in a city, and there is no bridge and no tunnel: a road crosses a valley on a bank and a hill in a cutting, and is up to 19% steep. Every street is 12 m and every road between cities 8 m, with no cars, no signs and no traffic lights. A field is a colour and its rows: the wheat doesn't stand.
* Outside the fields the ground changes material in cells: 1 m next to the camera, 16 m at the edge of sight.
* GI sees no sun shadows beyond 384 m of the camera.

### Showcase

One model of `Assets/` on a set made for it, seen through a lens. Pick the scene "Showcase (one model)", then the model in the Model popup under it; each model brings its own fog and lens settings, as a scene does.

| Set | Models | What is in it |
|---|---|---|
| Crypt | golem, harpy | A stone hall; a low sun (or moon) through three tall windows lays shafts across ground mist and through the model |
| Forge | demon, steampunk warrior | Dark brick, a glowing pit with a flickering light, embers rising into a column of smoke |
| Underwater | submarine | Dense blue-green water, five swaying shafts from the surface, sand, rocks, kelp, bubbles; the model drifts and bobs |
| Neon | battle maiden, cat robot | A glossy black floor between coloured light panels, tube strips, a scanner beam sweeping the model, haze |
| Workshop | owl, lab bench | A room at dusk: the sun's shaft through a window, a desk lamp, glowing jars on shelves, a stuttering tube light, dust in the air |
| Sanctum | sorceress, fantasy character | A round dais under one beam from high above, a ring of columns, a glowing cloud, runes circling the model |
| Studio | any other model | A dark cyclorama |

* Every set has the same rig round the model: a polished plinth with a glowing ring, a key spot from high in front, whose beam shows in the fog (the model's shadow cuts a dark shaft behind it), and two spots high behind it for its outline, their beams meeting at it in the fog. Most models turn slowly on the plinth.
* Particles (embers, bubbles, dust, runes) are small emissive shapes only camera rays meet (`maskLights`): they glow and bloom, but cast no shadows and light nothing, so they cost no light samples.
* The camera frames the model from its bounds: three-quarters from the front, slightly below its middle, the model filling about 70% of the frame's height.
* A model is found by a part of its file name, without regard to case. A model with no look of its own (any `.glb` you add to `Assets/`) gets the studio. The looks are a table in `Showcase.swift`: a new model is one row.

**The lens and the finish** (`Shaders/Post.metal`, the "Lens and finish" settings) work in any scene, but are on only in the showcase by default, so every other scene draws what it drew. They run on the frame's light at the output resolution, after the composite or after MetalFX's denoising scaler, before and after the tone curve:
* **Depth of field:** each pixel's blur circle grows with its distance from the focus (`aperture` is its radius in output pixels far behind it, at most 24). A gather of up to 64 taps on a golden-angle disc, each tap counted where its own circle reaches the pixel and spread over its circle's area, so bright points become discs; a tap behind a pixel can't blur over it, so a sharp model keeps its edge against a blurred background. Focus 0 is autofocus: the median depth of a patch at the centre of the frame, eased in over about ten frames.
* **Bloom:** six halvings from half the output size (13 taps; the first with a soft threshold and Karis's average, so a lone bright pixel doesn't flicker into a blob), then back up with a tent filter, mixed in before the tone curve.
* **Chromatic aberration**, **vignette** and **film grain** (luminance-weighted, new every frame) finish the image.

`METALRENDERER_SCENE="showcase,showcase=owl"` starts in the showcase (`showcase=` takes a part of a file name; without it, the first model). `METALRENDERER_POST="bloom=0.08,threshold=1,aperture=6,focus=0,vignette=0.35,grain=0.015,ca=0.0015"` sets the lens in any scene. `METALRENDERER_BENCH=showcase` renders every model on its set as the app shows it, paused at t = 5 s; then the first model without the lens, at 0.75× without MetalFX (the lens on the composite's light) and with the camera moving. `METALRENDERER_BENCH=showcasevideo` records a video's frames instead: each model for 6 s, the camera orbiting it, every other frame of the 60 Hz clock saved as a JPEG (`<setting>/f0001.jpg` and on, 30 fps) for ffmpeg to join. `METALRENDERER_GALLERY="owl|demon"` picks the models.

### Glass

Window glass is thin and clear, or tinted: the camera sees through it and sees its mirror reflection, and to light it isn't there.

* Glass is an instance mask (`Scene.maskGlass`); its material's albedo is the tint. Shadow, GI and reflection rays only meet geometry, so sunlight falls into rooms and a room's lamp lights the pavement, with no change to those kernels.
* `traceKernel`'s camera ray doesn't meet it either: the G-buffer holds the surface behind the pane, so direct light, GI, ReSTIR, the denoisers and the reflection pass light and filter that surface as usual.
* `glassKernel` (`Shaders/Glass.metal`) runs right after the trace: the camera ray again, against the glass alone, as far as the surface the trace found. For up to 4 panes it multiplies what comes through, (1 − Fresnel) × tint each, into the G-buffer's albedo, F0 and emission; for the first pane it traces one mirror ray, lights its hit with one light sample, and adds Fresnel × that to the emission.
* It is compiled in only for scenes with glass (a bit of the light-type constant), so every other scene draws what it drew, bit for bit, at the same speed.
* **Why a pass of its own:** `traceKernel` is short of registers. With the panes' rays inside it, every pixel of the city traced at a third of the speed (13.6 ms a frame from the road against 10.4); with only the ray through the panes inside it, as one call in a loop, the two kernels together were still 0.3 ms slower. One glass mesh per wall instead of per building changed nothing.
* **Cost:** 0.2 to 1.9 ms by day (the table above), more at night, when the mirror ray's hit draws its light from the light table.
* **Limits:** no refraction; glass doesn't tint or dim the light that passes it; the reflection's one light sample is filtered only by the upscaler (among many lights it is held low, so a dark pane doesn't sparkle); reflections off other surfaces see the room, not the pane.

### SDF shapes

A shape is a list of up to 32 nodes, joined one after the other: `((n0 op1 n1) op2 n2) …` (`SDFShapes.swift`). An instance places a shape the way an instance places a mesh, with any transform, and it can move. The **SDF shapes** scene (`METALRENDERER_SCENE=shapes`, `Scene+Shapes.swift`) has a row of primitives, a row of cut and blended shapes, a baked torus knot, and two glowing shapes that light the room.

* **Nodes.**
  * A node is a primitive: sphere, box (rounded), torus, capsule, cylinder (rounded), capped cone, or a baked grid.
  * It is placed by a rotation, a translation and a uniform scale, so its distances stay distances.
  * Its op is union, subtract or intersect. With a blend radius `k` the join is smooth: a polynomial smooth minimum, never more than k/4 below the sharp one.
  * Its material is an offset from the instance's. A union's surface takes the nearer node's material, and a cut face takes the cutter's.
* **Tracing.** Each shape has a structure of one box, as far plants' voxels do. Metal's intersection queries hand the box to the shader, which sphere-traces the shape inside it, in the instance's space, with `sdfMarch` (`Shaders/SDF.metal`), and never commits the hit:
  * The march stops within 0.1 mm, plus 0.1 mm per metre along the ray, well inside the 1 mm that a ray leaving a surface starts off it.
  * A ray that starts inside a shape meets the inside surface, as rays meet both faces of triangles.
  * Shapes with blends or grids step at 0.8 of the distance; exact ones at the full distance. A ray gives up after 128 steps.
  * The march returns the hit's normal (a tetrahedral gradient) and its material. Everything after the hit (`traceSurface`, every pass) needs nothing more from the shape: no buffers, no second march.
* **Baked grids** (`SDFVolume.swift`). A mesh is sampled about 64 times along its longest side, with two cells of room around it, and stored as `half`s.
  * The distance is exact, to the nearest triangle.
  * The sign is a vote of three. A sample is inside if an odd number of faces is crossed counting along x, y and z, in at least two of the three. A mesh with a few holes or doubled faces still has its inside right.
  * Outside the grid the distance is a bound: the distance to the grid plus the least of its face samples.
  * Grids are cached by a hash of the mesh (`GeneratedCache`).
* **Glowing shapes are lights.**
  * A shape whose material emits is turned into triangles: surface nets, each vertex moved onto the surface and then 0.15 of a cell outward. These triangles become an ordinary mesh light, so ReSTIR, MegaLights, the light tree, the light table and the fog sample it unchanged.
  * Because the triangles lie just outside the surface, a shadow ray to a point on them never meets the shape first.
  * A shape of several materials gets a light per material that emits.
* **Textures.** An SDF hit has no UVs. Base colour, metallic-roughness and emissive textures are projected along the instance's three axes, once per unit, and blended by the normal (triplanar). There are no normal maps.
* **Compiled in only where used.** A scene without SDF shapes compiles none of this (bit 22 of the light-type constant) and traces what it traced before. In a scene with shapes, every ray is an intersection query, as with far plants' voxels.
* **Limits:**
  * Shapes can't be in instance groups.
  * A node's scale is uniform.
  * A shape's nodes don't animate; its instance does.
  * Thin features under about 2 mm can be skipped by the 1 mm offset of a ray that leaves a surface.

### Physics

Rigid bodies that are SDF shapes, joints between them (ragdolls), particles and cloth, simulated on the GPU (`Physics.swift`, `Shaders/Physics.metal`), with the same steps on the CPU as their reference. The **Physics** scene (`METALRENDERER_SCENE=physics`, `Scene+Physics.swift`) is an arena:
* `bodies` shapes of every kind drop in layers onto a ramp, a tower of blocks and each other, and a heavy ball rolls in at the tower's foot;
* `particles` balls pour into a bin, heap up and spill over its rim;
* a cloth (`cloth` vertices a side) hangs by two corners from a rod and falls over a ball;
* a torus knot baked into a distance grid stands on a pedestal; it is a static collider like the rest.

The scene list's keys are `bodies=96`, `particles=2048`, `cloth=36`, `substeps=16` and `physics=auto|gpu|cpu`.

The **Ragdolls** scene (`METALRENDERER_SCENE=ragdolls`, `Scene+Ragdolls.swift`) drops `ragdolls=24` ragdolls in layers over the top of a staircase, lying across it and thrown forward: they tumble down the steps and pile up against posts and a bench at its foot. Each ragdoll is 11 bodies (`Scene.addRagdoll`): a pelvis, a chest, a head, upper and lower arms and legs, all capsules but the head, joined by 10 joints. It shares the physics scene's look, `substeps` and `physics`.

The scene has a look of its own that leaves the GPU to the simulation (`RenderSettings.usePhysicsLook`, applied with the scene's other defaults and by benchmarks moved to it):
* no GI and no reflections;
* traced at 0.375 of the window, upscaled 3× to 1440×900.

On the M1 Max a frame then renders in 5 ms instead of 15. The breakdown of the 15: reflections 4.7 ms, radiance cascades 2.9, and the trace and the upscaler, which the smaller frame cuts from 6.6 to 4.7 ms. Nothing in the scene is metal, since a metal without reflections renders black. The panel can turn GI and reflections back on.

* **XPBD with small substeps** (Müller et al. 2020, Macklin et al. 2019):
  * A step is 1/60 s of `substeps` substeps (16), one solver iteration each.
  * A substep moves every body by its velocity, pushes its contacts apart (static friction holds them), takes the velocities from how far the bodies went, then applies dynamic friction, restitution, and rolling and spinning resistance (4 mm and 2 cm × the normal force; without them a ball, a cone or a lying cylinder rolls or spins on the spot for ever).
  * Contacts are solved **Gauss-Seidel by colour**. Once a step the pairs with contacts are coloured so that no two of a colour share a body (Jones-Plassmann: in rounds, each pair that outranks its uncoloured neighbours, by a hash, takes the lowest colour they don't have). The pile takes 9–15 colours, and each substep solves them a colour at a time, every pair's contacts one after another, in place. Averaging each body's contacts (Jacobi) instead rocked resting bodies: a tilted box's one penetrating corner took the whole correction.
  * Small substeps are what make a GPU-friendly solver stack. At 8 substeps a tower of 8 crossed layers sinks through the floor; at 12 it holds to 3 mm.
  * **Sleep.** A body that has moved less than 5 cm/s, and turned its mass slower than 2 cm/s, for half a second falls asleep once the bodies it has contacts with have been still for half as long. Both are measured over each step from where it began (its velocities say little at rest: they are what the last substep's kicks left). Its mass's turning is its turn rate times its radius of gyration about the turn, at most 15 cm: 0.13 rad/s for a body that size or more, more for a ragdoll's forearm turning about its length (it jittered at 0.27 rad/s that way, 1 cm/s at its surface, and a pile of ragdolls never slept; at 0.08 rad/s, 24 ragdolls took 48 s). Something touching it wakes it only when it moves faster than 10 cm/s or turns its mass faster than 4 cm/s (0.27 rad/s at 15 cm), so a neighbour settling beside it doesn't, nor a thin limb jittering. (Without the cap, a tower's long blocks needed to be stiller than before, and never slept.) The physics scene's 96 bodies are all asleep by 12 to 22 s.
* **Collision is one path for every pair** (`PhysicsCollide.swift`):
  * A shape is a distance in its body's space plus surface samples, each a small sphere. A sphere is one sample; a capsule is five along its core; a box is its corner and edge spheres (its rounding); any other SDF shape is 64 points of its surface, its boxes' corners first.
  * A pair's contacts are each side's samples against the other's distance. That is exact for spheres and capsules against anything, and for anything against a plane.
  * Two flat-sided shapes also step down one's field along the other's surface, from each side. That finds an edge across an edge, which no corner is in.
  * The distances are exact formulas for spheres, capsules, boxes and planes (their gradients too: a box's inside takes its nearest face's normal). Every other shape uses its field, so CSG, blends and baked meshes collide like the primitives.
  * Contacts are kept as Bullet keeps a manifold: four at most, the deepest always, the rest for the most area. They share one normal where they roughly agree, so a corner on a corner doesn't push sideways.
  * Contacts are found at the start of a step, with a speculative margin for how far the pair can close in a step, and anchored in each body. A sphere's anchor is its centre, so it stays under the sphere as it rolls.
  * They are found again every 4 substeps for the pairs that had contacts and of which a body moves. Found once a step, a turning body's contacts stayed where it had been: a cylinder rolling on its rim sank a stale contact into the floor, and the push out of it launched it at 1.2 m/s. Every 8 substeps isn't enough (a pile is a third awake at 12 s).
* **The GPU's step** (one serial "physics" pass, ahead of the acceleration structures):
  * A hash grid over the bodies' bounding spheres, from per-bucket linked lists.
  * Each body's partners, the nearest 16, with static colliders first so a crowded body never drops the floor. (Keeping the lowest-numbered 16 instead, a tower's middle blocks dropped a body dragged into them, and it passed through.)
  * Each pair's contacts, a SIMD group a pair: the lanes test 32 samples at a time, and the manifold takes them in the samples' order.
  * Each run of 4 substeps in one threadgroup, after the narrow phase: barriers stand in for dispatches. The step's first run colours the pairs (a counting sort by colour), and each substep solves a colour's pairs a thread a pair. Pairs the 64 rounds leave would be solved by one thread in entry order; the scene leaves none.
  * Then a pose kernel writes every body's and particle's instance record (and Metal's descriptor) where the steps left it.
* **The same every time:**
  * Nothing adds floats atomically. No two pairs of a colour share a body, so the order within a colour doesn't change a bit.
  * A pair is solved only if both of its bodies keep it among their nearest. The colours see a pair through both bodies' lists, and one that only the lower body kept took a colour beside the higher one's other pairs: two threads moved that body at once, and a pile of 512 bodies (or 24 ragdolls) ran differently every time after a second.
  * Two GPU runs are bit-identical, and the GPU's steps match the CPU's within 0.1 mm for half a second. Further on, a pile tells float rounding apart.
  * Going back in time replays from the start, so a benchmark's still at 5 s is the same however it was reached.
* **Particles** are small balls, each an SDF sphere instance.
  * They find each other in a grid of their own and collide at the same substeps: with each other (Jacobi, averaged, with friction so they heap) and with the static colliders and bodies.
  * A particle in contact that went slower than 10 cm/s over a substep stays where it was (Macklin et al. 2014's particle sleeping), unless a body is pushing it or it is a cloth's. Without that the averaged pushes kept a heap fizzing: half its particles still moved at 12 cm/s after 6 s.
  * The bodies push the particles; the particles don't push back.
* **Cloth:**
  * Its vertices are particles whose distance constraints (stretch, shear, bend) are coloured once, so no two of a colour share a vertex. Each substep solves them a colour at a time (Gauss-Seidel).
  * Air drag damps it. Pinned vertices never move.
  * It collides with the bodies and static colliders, not with itself or the particles.
  * Its mesh is a deforming mesh like the crowd's poses. The pose kernel writes its vertices, last frame's (for motion vectors) and its normals, and Metal refits its structure.
* **What it costs** (M1 Max; the physics scene's first 5 s moving, a step a frame, 16 substeps, 2048 particles and a 36 x 36 cloth; `METALRENDERER_BENCH=physics`):

  | Bodies | "physics" pass (GPU) | Whole frame (GPU, the scene's look) | CPU instead (render thread, per frame) |
  |---|---|---|---|
  | 96 | 5.9 ms | 11 ms (90 fps) | 17.5 ms |
  | 512 | 11.7 ms | 19 ms | |
  | 2048 | 41 ms | 52 ms | |

  * Coloured Gauss-Seidel, the contacts found 4 times a step and the particles' rest cost 1.24–1.4× the Jacobi solver's 4.6 / 9.6 / 21 ms, which never let the pile rest (2048 bodies: 26 ms).
  * Keeping each body's nearest partners rather than its lowest-numbered took 2048 bodies from 26 to 42 ms: their pile has up to 9,000 pairs touching (14–18 colours) that were partly dropped before, and passed through each other.
    * Colouring every partner pair rather than those with contacts took more than 32 rounds: the pairs left over went to one thread, and 2048 bodies took 364 ms.
    * Colouring again at every refresh settles a pile a few seconds sooner, at 7.3 / 15.8 / 36 ms.
  * What made it fast before:
    * Every substep in one threadgroup: with three dispatches a substep, 16 substeps cost 6.6 ms for 96 bodies.
    * A SIMD group per pair in the narrow phase: 0.8 to 0.35 ms.
  * At thousands of bodies one threadgroup runs out of threads: the next thing to try is dispatches per stage above a size, measured against it.
* **Joints** (a ragdoll's; Müller et al. 2020's positional and angular constraints):
  * A joint holds a point of each of two bodies together. A **ball joint** keeps the angle between their axes within a cone (a shoulder's leans out and forward from the arm hanging down, a hip's forward) and their twist about them within a range; a **hinge** keeps its axes together and its turn about them within a range (elbows bend one way, knees the other). The pose the bodies are built in is every angle's 0.
  * Each substep solves them before the contacts, a colour at a time (they never change, so they are coloured once: a ragdoll takes 4), twice over. Once over left a whipping chain's anchors 2.5 mm apart, twice 0.55 mm. Before the contacts, so that static friction undoes what the joints slid a resting body along; after them, a ragdoll's chest crept a little every substep and never slept. The contacts then have the last word: at the hardest landings in a pile the anchors part by up to 8 mm for a moment, and by 0.2 mm at rest.
  * A joint's limits are angles taken with `atan2`, corrected by the whole excess, about the axis that moves them back.
  * Damping (6/s) slows two joined bodies' relative turning, each body turned about the joint with its velocity, by their inertia about it. Slowing only their turning about their centres hardly slowed a head swinging on its neck: the joint gave it back from how the head still went round it. At 6/s a pile of 24 ragdolls sleeps by 15 s; at 2/s by 27 s.
  * Two bodies a joint joins don't collide (`info.w` holds the body a body hangs from); every other pair of a ragdoll does.
  * A ragdoll sleeps and wakes whole: if one of its bodies is awake (or held) at a step's start, they all wake, and none sleeps while any can't. One asleep would hold its joints still under the others.
  * Elbows and knees go 0.1 rad past straight, so that the pose they're built in isn't on a limit, where float rounding decides whether they're pushed back.
  * What ragdolls cost (M1 Max, the ragdoll scene's first 5 s moving at the physics look; `METALRENDERER_BENCH=ragdolls`):

    | Ragdolls (bodies) | "physics" pass (GPU) | Whole frame (GPU) | CPU instead (render thread, per frame) |
    |---|---|---|---|
    | 8 (88) | 2.0 ms | 5.5 ms | 2.4 ms |
    | 24 (264) | 2.9 ms | 6.9 ms | 6.4 ms |
    | 96 (1056) | 7.1 ms | 12.5 ms | |
* **Grabbing.** A click on a body grabs it where the cursor meets it: the ray is sphere-traced through each body's distance, from the poses the frame was drawn with (on the GPU, the 3-frames-late snapshot). A drag moves the grab point on a plane through it facing the camera, and the scroll wheel moves it nearer or farther. Each substep pulls the point 3 % of the way to the target, through the body's inverse mass and inertia there, so a body held off its centre swings and hangs; its velocities fade at 8/s while held, so it doesn't swing about the cursor. Contacts are solved after the pull, so a held body can't be pushed through the floor. Release lets it go with its speed, so a flick throws it. The GPU reads the grab from a small buffer per frame slot.
* **The CPU's copy** of the bodies comes from a snapshot the pose kernel writes per frame slot. It is read once the slot's frame is done: three frames late, but the same three every time.
* **Backend.** `auto` steps on the CPU below 64 bodies and particles, where a dispatch costs more than the work. Then the CPU writes the instances, and a cloth is uploaded each frame for the GPU to draw.
* **Checked:** `PhysicsTests` covers:
  * resting, stacking, bouncing (restitution), sliding or holding on a slope (friction);
  * crossed bars' edge contact;
  * mass properties;
  * particles heaping and a ball pushing through them;
  * cloth hanging without stretching and draping over a ball;
  * picking, a grab lifting a box and letting it go, a dragged box knocking the tower over, and a hold on the GPU against the CPU;
  * coming to rest: the scene's pile asleep and still (CPU, and GPU at 20 s), at least 7 of 8 drops of each body shape (on the floor and on a box) asleep within 6 s, the tower not drifting, a box on a ramp not creeping, a particle heap still;
  * and `RagdollTests` covers joints: a swinging chain's anchors within 1 mm, a hinge and a ball joint stopped at their limits (within 0.03 rad), joined bodies never partners, six ragdolls tumbling down the stairs with their joints holding and asleep within 24 s, one sleeping and waking whole and lifted by a hand, and on the GPU the drop against the CPU, two runs of a pile bit-identical, and 24 ragdolls all asleep at 25 s (15 s here);
  * GPU against CPU, and two GPU runs.
* **Limits:**
  * Rigid bodies and SDF shapes only: a triangle mesh collides through a baked grid.
  * Particles and cloth don't push the bodies.
  * No cloth self-collision. Joints are rigid: no motors, springs or breaking, and a ball joint's cone is round.
  * A pair is coloured, and its contacts refreshed, only if it had contacts at the step's start: one that first touches mid-step waits for the next step. A fast thin shape can still pass through a thin one.
  * Glowing bodies' lights follow the CPU's copy, three frames late.
  * Going back in time replays from the start without the grabs.

### Hair and fur

Strands of hair simulated on the GPU (`PhysicsHair.swift`, `Shaders/Physics.metal`), with the same steps on the CPU as their reference, drawn as Metal's round curves and lit by a hair BSDF (`Shaders/Hair.metal`). The **Hair and fur** scene (`METALRENDERER_SCENE=hair`, `Scene+Hair.swift`) drops `fur=6` furry bodies (balls, a rounded box, a capsule) at the top of a ramp to roll down it, beside a mannequin with long hair on a stand (a ragdoll held at its pelvis and chest), swaying, in a gusting breeze. It shares the physics scene's look, `substeps` and `physics`.

* **Guides and drawn strands** (as TressFX has them): a few thousand guide strands are simulated, each 6 to 12 vertices from a root its body holds, and around each guide `hair=12` strands are drawn (`Scene.addHair`: roots spread over the body's surface, grown out along its normal and combed over). A drawn strand is its guide offset across it (in a frame carried along it), drawn in toward it by the tip (clumping) and curling about it: `physicsHairCurvesKernel` writes their control points every frame, as the cloth's vertices are written.
* **A step** (`PhysicsWorld.stepHair`, `physicsHairKernel`), after the bodies' substeps (the strands never push a body back, as the particles don't), as many substeps as theirs, each strand one thread's, its vertices one after another (no colouring; every run the same):
  * the root follows its body, its pose between where the step began and where it ended;
  * the other vertices move by their velocities, which the air (2/s) takes toward the breeze, and gravity;
  * **global shape**: each is pulled toward where it rests on its body, stiffest at the root;
  * **local shape**: each segment is turned about its middle toward its rest direction as the segment before it carries it (curls stay curls as hair hangs). Turning only its far end, as follow-the-leader moves vertices, made a stiff strand flutter at a metre a second: a load that follows the strand's own turn;
  * **length**: follow-the-leader from the root (Müller et al. 2012): each vertex at its length from the one before, then pushed out of the bodies and static colliders near the strand (8 at most, with friction);
  * velocities from how far the vertices went, less half of how far the next one was moved to keep its length (DFTL's damping: without it a loose strand never settles; at Müller's 0.9, with the shape's pulls, a tilted fur strand kept a zigzag at half a metre a second).
  * Stiffness is how fast a shape springs back (rad/s): a substep pulls (ωh)² of the way back, so gravity bends a strand by about g/ω² whatever the substeps. Fur is 80 rad/s at the root and 30 at the tip (a strand out sideways sags 9 mm); long hair 10 at the root and 0 at the tip, 4 locally. (TressFX's share of the way a substep: 1% held long hair against gravity to a millimetre at 16 substeps.)
  * A strand on a sleeping body stops once no vertex has gone 2 cm/s over a step, and wakes with the body.
* **Curves** (MSL 3.1 or later: `HAIR_CURVES`): a drawn strand is round Catmull-Rom segments of 4 control points, its first and last points phantoms past its ends, its radius tapering to the tip. A group of strands is one mesh with no triangles (`Scene.addCurves`): everything that reads triangles skips it, its control points sit in the scene's vertex buffer (last frame's after everything, for motion vectors), and Metal's structure over them (`MTLAccelerationStructureCurveGeometryDescriptor`) is refitted every frame with the deforming meshes'. The ray queries meet curves where the scene has them (`HAIR_CURVES`, feature bit 20: `curve_data` queries, `CurveLevels`), and a hit on one (`HIT_CURVE`) is a surface from the segment's point and tangent at the curve's parameter, its normal out from the axis.
* **The hair BSDF** (Chiang et al. 2016, as pbrt-v3's `HairBSDF`): R, TT and TRT lobes and the rest, each a longitudinal spread shifted by the cuticle's 2° tilt, Fresnel and the pigment's absorption (from the strand's colour, Chiang's fit), and an azimuthal logistic; β_m = β_n = 0.3. Light between strands, most of a pelt's colour, which a path tracer gathers and the lobes leave out, is a stand-in: Kajiya-Kay's diffuse at 0.7 of a Lambert surface's. A hair material is `addHairMaterial` (params.z = -1); its pixels keep their tangent in the G-buffer's alphas (albedo.a and geoNormal.w + 2) and the offset across the strand comes back from the normal, so every kernel that lights the visible surface lights strands by the BSDF: the trace's light loop, many lights and their reuse, mesh lights, ReSTIR DI, MegaLights and the shadow denoiser's composite. A shadow ray toward a light behind a strand starts 2 mm along it, out of its own curve.
* What hair costs (M1 Max, Metal's tracer in software, the hair scene's first 5 s moving at the physics look; `METALRENDERER_BENCH=hair`). The scene has 4,781 guides (32,172 vertices: 700 on each furry body, 581 on the mannequin's head); the head draws 1.5 times as many strands a guide as the fur:

  | Strands a guide | Drawn strands (control points) | Curves' refit ("blas") | "physics" pass (bodies and hair) | Trace | Whole frame (GPU) |
  |---|---|---|---|---|---|
  | 4 | 20,286 (186,000) | 1.7 ms | 2.8 ms | 10.2 ms | 16.8 ms |
  | 12 (the default) | 60,858 (550,000) | 4.0 ms | 3.0 ms | 16.8 ms | 26.2 ms |
  | 24 | 121,716 (1.1 M) | 7.4 ms | 3.3 ms | 23.0 ms | 35.8 ms |

  The same scene on the custom tracer (since removed), without its strands, rendered in 4.4 ms. Stepped on the CPU instead (`physics=cpu`, 4 strands a guide), the bodies and the 4,781 guides take 10.2 ms a frame on the render thread; the GPU's whole "physics" pass, bodies and hair, takes 2.8 to 3.3 ms. The curves are refitted every frame, paused too.
* **Checked:** `HairTests` covers a strand's segments within 3e-6 of their length in a gusting breeze, long hair hanging, fur keeping its shape (upright still, sideways sagging 9 mm), roots following a spinning body to 1e-5 m, hair falling over a ball onto the floor without sinking into either, strands resting and waking with their body, the breeze blowing hair, the scene's curve meshes, and on the GPU the first steps against the CPU, two runs bit-identical, the drawn strands against the CPU's to 5e-7 m, and the fur at rest; and the BSDF's white furnace (1 within 1%) and its highlight 2α off the mirror direction.
* **Limits:**
  * No hair-hair collision (strands pass through each other), and the hair never pushes a body.
  * The BSDF is evaluated for direct light only: GI on hair (and hair seen in GI's bounces) is Lambert, and reflections skip it. The physics look has GI off.
  * Area lights light a strand from their middle.
  * The roughnesses are the same for every hair material (the G-buffer keeps no more).
  * Velocities from positions over a substep: the GPU's rounding parts its hair from the CPU's by millimetres in five steps, as two swinging pendulums would.
  * Fur squeezed between two resting bodies keeps stirring by millimetres a step (11 strands of 2100 in the test).

### Soft bodies

Jellies, simulated as tetrahedral lattices on the GPU (`PhysicsSoft.swift`, `Shaders/Physics.metal`), with the same steps on the CPU as their reference, and drawn as their shapes' surfaces bent with them. The **Soft bodies** scene (`METALRENDERER_SCENE=softbodies`, `Scene+Soft.swift`) throws `soft=16` of them (balls, rounded cubes, capsules and pucks, every fifth a stiffer rubber one) onto a landing at the back of the studio, to flop down steps, squeeze past pegs and pile up; `cells=6` sets their lattices' fineness. It shares the physics scene's look, `substeps` and `physics`.

* **The lattice** (`SoftModel`): a cubic grid over an SDF shape, `cells` cubes along its longest side (at least two thirds as many along its shortest), each cube kept whose centre is inside the shape shrunk by a particle's radius (0.35 of the spacing) and none of whose corners is far outside it, and cut into six tets along its main diagonal (Freudenthal's, so neighbouring cubes share faces). Its corners are particles; those on its outside are moved onto the shrunk shape, so that their balls reach the shape's surface. Each shape's lattice is made once and placed per body.
* **A substep** (in the particles' substeps, `PhysicsWorld.solveTets`): every edge a link (XPBD distance, with the cloths' links, coloured with them), then every tet's volume (XPBD on six times it, Müller et al. 2020), a colour of tets at a time (no two of a colour share a particle: 29 colours), both with Macklin et al. 2016's damping of what moves along them (3 s for the links), and the air's 0.3/s. A jelly's links give (compliance 4e-3), a rubber one's hardly (2e-5); the volume almost not (1e-9: fully rigid, linear tets lock and a jelly stands stiff).
* **Collision** is the particles': a soft body's particles meet the static colliders, the bodies, loose particles and other soft bodies' particles, not their own body's. Unlike a heap's particle, a soft body's takes its pushes summed (averaged, the floor's push halved a box's shoving it, and a jelly on another sank 3 cm into it) and at up to 10 m/s rather than 3 (a box sliding at 3 m/s pushed it no faster than it came). One-way, as the cloths: a soft body never pushes a body back.
* **Drawing**: the shape's surface (surface nets, 20 cells along its longest side) is a deforming mesh, as the cloths' are. Each of its vertices is where the tets it and its ring's vertices are in put it, averaged (`physicsSoftMeshKernel`): it is a little outside the lattice, and one tet alone creases the surface where two bend apart; any rigid motion stays exact. Its normal is the triangles' around it (`physicsSoftNormalsKernel`), not a tet's own deformation's (which shaded the creases). Metal refits its structure with the other deforming meshes'.
* What soft bodies cost (M1 Max, the soft body scene's first 5 s moving at the physics look, on the custom tracer, since removed; `METALRENDERER_BENCH=soft`). Each body is 63 to 275 particles at 6 cells (the cube most), and 1,800 drawn vertices on average:

  | Soft bodies (particles, tets) | "physics" pass (GPU) | Whole frame (GPU) | CPU instead (render thread, per frame) |
  |---|---|---|---|
  | 16 (3,036, 9,864) | 6.3 ms | 10.0 ms | 35 ms |
  | 48 | | 20.6 ms | 91 ms |
  | 128 | 49.8 ms | 55.0 ms | |
  | 16 at 10 cells | | 32.0 ms | |

  The same scene paused renders in 3.7 ms. The steps are most of it: every substep in the one threadgroup the bodies' run in (16 substeps of 14 link colours and 29 tet colours, a barrier each), so from a few dozen jellies the work no longer spreads over the GPU. A threadgroup per soft body for its links and tets is the next thing to try.
* **Checked:** `SoftBodyTests` covers the lattice (every tet the right way out, each link once, the balls reaching the surface), the colours sharing no particle, the drawn surface at rest where the shape is (to 1e-5 m, its normals the shape's), a jelly dropped on the floor at rest within 8 s with its volume within 0.3 % and its drawn surface within 2 mm of the floor, a soft jelly sagging more than a rubber one, a jelly dropped on another landing on it without their balls passing into each other's, a heavy box shoving a jelly along without it sinking in, a jelly crushed to 40 % of its volume recovering, the scene's meshes, and on the GPU the first 20 steps against the CPU (within 2 mm: the rounding parts them as the jellies land), two runs bit-identical, the drawn surfaces against the CPU's to 5e-7 m, and the scene at rest at 15 s.
* **Limits:**
  * One-way: a body lower than a jelly goes through it (the jelly can't lift it, and its particles squeeze round it), and resting on a jelly a body sinks to the floor.
  * No self-collision: a soft body folded onto itself passes through itself.
  * Contact is the lattice's balls: the drawn surface can dip a few millimetres into what it rests on, and a heavy jelly slides off another.
  * A jelly settles over several seconds (the scene, by about 15 s); there is no sleeping.
  * The drawn surface still undulates a little where a jelly is squashed hard.

### Muscles and skin

Flesh on skeletons: soft tissue held to bones, with muscles in it that contract as the joints they cross bend, under a skin (`PhysicsFlesh.swift`, `PhysicsRig.swift`, `PhysicsSkin.swift`, `Shaders/Physics.metal`), on the GPU with the same steps on the CPU as the reference. The **Muscles and skin** scene (`METALRENDERER_SCENE=muscles`, `Scene+Muscles.swift`) has the crowd's Y Bot dance on the spot, three hip hop dances and two breakdance freezes, in a ring of a dozen balls, and throws `fleshragdolls=3` ragdolls with flesh down steps at the back. It shares the physics scene's look, `substeps` and `physics`.

* **Two kinds of skeleton.** A ragdoll's bones are its bodies (Physics). The character's are **kinematic bodies**: shaped to the mesh's vertices each bone moves most in the bind pose (a limb a capsule from its joint to the next, 85 % of them inside; the trunk, hands and feet rounded boxes; the head a sphere), and moved by a **table of poses**, a row a step, baked before the first from its clips (`CharacterRig`: 2.5 s idle; Hip Hop Dancing, Breakdance Freeze Var 2, Hip Hop Dancing (1), Breakdance Freeze Var 3 and Hip Hop Dancing (2), each once and whole; 2 s idle again; half-second crossfades; 48.3 s and round again). It dances on a spot: the freezes' travel (0.24 and 0.31 m/s, taken out of their keys when they were retargeted) is put back as they dance and taken back a little every step over the routine, so the table repeats, and the character strays 1.3 m from its spot at most. Both backends read the same rows and blend between a step's two the same way, so they agree bit for bit, and a replay from the start is the run again. A kinematic body has no mass: what touches it, it pushes, carries along by friction (from how far it went that substep) and wakes, and nothing moves it (`kinematicBit`; it pairs with no static and no other kinematic body).
* **The flesh** (`addFlesh`) is a soft body's lattice (`SoftModel`, 3.5 cm by default) over the figure's bones' shapes blended together (the ragdoll's grown by 1 cm; the head, hands and feet left out: they are drawn on their bones). A tet joins two bones' flesh only if one hangs from the other and it is at their joint, so an arm lying along the trunk, or two legs, keep apart (a slab is cut between the character's thighs, which its fitted capsules make meet). Each particle is **pinned** to its two nearest joined bones by how deep it is (Position-Based Skinning, Abu Rumman and Fratarcangeli 2015; Projective Skinning, Komaritzan and Botsch 2018): its target is where each bone puts its rest point, blended by weights that fall off as depth^-4. A core particle one bone holds (depth under 0.45, its weight over 0.9) has no mass and sits on its target; out to 0.85 it is pulled there by an XPBD constraint softer the deeper it is (1e-7 to 1e-4); outside that it is free, to jiggle. It starts where its bones put it. Its links are stiffer than a jelly's (2e-4; the free outer layer's 4e-5, the embedded skin's tension), its tets keep their volume (1e-11: a jelly's 1e-9 gave way to a contracting muscle), and it doesn't meet its own bones.
* **Muscles** (`MuscleSpec.limbs`): each side's biceps and triceps (the elbow), deltoid (the arm raised), quadriceps and hamstrings (the knee), and the calf (the ankle, where there is a foot: not on a ragdoll). A muscle is the tets inside its belly, a capsule along its bone to one side of it; each tet's **fibre** runs along the belly, stored as g = Dm^-1 f (its rest edges' inverse times the direction), so that its edges now times g is the fibre now. An XPBD constraint (Romeo et al. 2020) pulls that length toward 1 less its shortening, 40 % of it at full activation in the belly's middle (sin along it), then the tet's volume is put back (in that order: the other way round, each pass's fibre took the volume back out), so the belly shortens and **bulges**. The activation is the angle between two bones' axes between where it starts and where it is full (the elbow's: from 0.35 to 2 radians), worked out from the bones each substep (nothing to replay). Belly particles are held loosely (pinned hard or firmly, the belly couldn't move out), and tets squashed flat at rest get no fibre (theirs was up to 25 times as stiff as their neighbours' and shook the flesh).
* **The skin.** Embedded (`skin=embedded`, the default): the drawn mesh is in the flesh's tets as a soft body's surface is, the character's own (its half-detail level, 24,000 vertices, welded where its pieces meet so its normals are smooth; its head, hands and feet on their bones' bodies), a ragdoll's its flesh's surface (surface nets). Sliding (`skin=sliding`, the character's): a shell of its own, a surface of the flesh's shape 2.5 cm apart (4,064 particles), held together by its triangles' edges and bends across them, each particle held to where it rests in the flesh hard along the normal there (from a point 1 cm under it in the same tet) and softly across, no further than 2 cm (`solveSkin`, after the tets); the mesh rides its nearest triangle, out along its normal. One-way: the flesh never feels it.
* **The écorché** (`body=muscles`, the character's; `MuscleAtlas.swift`): the character drawn as its muscles, red with white tendons, over its bones, like Unreal's Chaos Flesh muscle model ("Emil", which is Unreal's own content, so these are made here). Its skin, the whole mesh (its coarser levels, simplified when the character cache is built, aren't symmetric), becomes a signed distance on a 6 mm grid (`BodySurface`): the Y Bot is made of panels and joint pieces that overlap and leave its elbows hollow, so which side is in comes from flooding the grid from outside around the skin (a gap under about 2.4 cm closes), the distance is to the triangles the flood meets, the rig's bone shapes 8 mm in count as inside within a centimetre of it, and the grid is smoothed. On it 37 muscles a side (`MuscleAtlas.muscles`: the neck's, the shoulders' three deltoid heads, the chest's, the four segments of the rectus abdominis, the back's, the arms' and forearms', the hips' and thighs', the calves' and shins') each run from origin to insertion through marks on the bones (a place along a bone or up the trunk and an angle round it, out to the muscle's depth under the skin), as a tube wider along the skin than into it or a sheet across two to four strands; each is clipped 4 mm under the skin, carved from the layer above, and shares with its own layer's neighbours where they overlap (cut where it is as deep in each), meshed by surface nets at 5 mm (`SurfaceNets`, factored out of `SDFShape.triangles`) without the undersides a fascia, the skin 1.4 cm deeper, hides. Its textures run along each muscle: white at its tendons into the red of its belly and back, with fibre stripes in its colour and its normals. It is one mesh of 195,000 vertices (106,000 of them the muscles', 63,000 the bones') in the flesh as the skin is, so the same muscles bulge it (the left biceps 3.4 mm further out from the arm's axis active than relaxed at the most bent elbow); building it takes 3.1 s at the scene's start. Moving, the scene's frame is 21.5 ms (21.6 before it had bones: theirs ride their bodies rigidly, so they cost only the refit over their vertices) against the skin's 20.1 (the physics pass's soft mesh kernel and the refit over its vertices); paused, 5.3 ms.
* **The skeleton** (the écorché's; `SkeletonAtlas.swift`): 77 bones under the muscles, in place of the character's grey head, hands and feet. The skull (the head's skin 6 mm in, cut above the teeth, its orbits, nose and temples hollowed and its cheekbones and their arches raised), the jaw and two rows of teeth; 24 vertebrae, the sacrum and coccyx; 12 ribs a side and the sternum; and each side's clavicle, scapula, humerus, ulna, radius, hand (the carpals, and a metacarpal and phalanges on each of the character's finger joints), hip bone, femur, patella, tibia, fibula and foot. Each is a few round cones, ellipsoids and thick triangles joined smoothly, placed from the rig's joints and the marks the muscles use, sized to the figure's height, kept 3 mm under the skin and meshed by surface nets at 2 to 4.5 mm. Where a bone is bare in life (the skull, a clavicle, the sternum, the spine's processes, the iliac crest, a kneecap, the shin, the ankles, an elbow's point) it is placed 4 mm under the skin, and the muscles and the fascia, carved from the bones' distance (a 6 mm grid of the nearest one's), leave it showing; the fascia closes off short of the head, the wrists and the ankles. What the fascia hides of the rest isn't drawn (156,000 vertices built, 63,000 drawn). Each bone rides its rig bone's body rigidly (a rib its vertebra's, the kneecap the shin's).
* **A substep**: the bodies and particles move (a kinematic body to its table's pose), then the muscles' activations and the pins, the links, the tets with their fibres, the skin's holds, and the particles' collisions (a barrier between each).
* What it costs (M1 Max, the scene's first 5 s moving at the physics look; `METALRENDERER_BENCH=muscles`). A ragdoll's flesh is 1,793 particles at 3.5 cm, the character's about 2,060; with the character and one ragdoll the scene has 3,852 particles, 12,270 tets in 29 colours, and 22 muscles over 1,893 tets (the default's 3 ragdolls about 7,450 particles):

  | Setting | "physics" pass (GPU) | Whole frame (GPU) |
  |---|---|---|
  | The default (3.5 cm, 3 ragdolls) | 15.6 ms | 19.5 ms |
  | Lattice 5 cm | 6.6 ms | 11.5 ms |
  | Lattice 4 cm | 11.0 ms | 18.5 ms |
  | Lattice 3 cm | 26.2 ms | 30.5 ms |
  | No ragdolls | 5.2 ms | 8.5 ms |
  | 6 ragdolls | 25.1 ms | 29.5 ms |
  | Sliding skin | 21.0 ms | 24.8 ms |

  Stepped on the CPU instead it takes 96 ms a frame on the render thread. Paused, the scene renders in 3.9 ms. As with the jellies, the steps run in one threadgroup; a threadgroup per figure (its flesh is one-way, so it can run from the bones' poses) is the next thing to try.
* **Checked:** `MuscleTests` covers a kinematic body following its table (exactly) and carrying a box on it (to 1 mm over 0.68 m) without letting it sleep; the character's rig (its bones' thicknesses) and its routine (every clip there, no bone jumps but Freeze Var 3's own foot spin, the last step into the first an idle's, within 1.5 m of its spot); the flesh held to its bones (the character's core exactly, a ragdoll's to 0.03 mm, the rest within 2.3 cm, and 5.7 cm on a ragdoll landing); an active fibre shortening to the length asked with its tet's volume within 0.3 %; and on the GPU the first 10 steps against the CPU (within 0.1 mm), two runs and a replay bit-identical, the drawn flesh against the CPU's (to 1.5e-6 m), the left biceps at the step its elbow is bent most in the first 15 s, in the first breakdance freeze (2.8 mm further out active than relaxed, swollen 10.5 %), and the sliding skin after 4 s (on the flesh along its normal, slid 5 mm at most); and the écorché: its 74 muscles each there and under the skin (all by the fat), its sides mirroring to 3.1 mm, its surfaces branching at 0.25 % of their edges (surface nets'), drawn by the GPU as the CPU does (to 7.2e-7 m), its biceps bulging, and its muscles out of its bones (all but 1 vertex); and its skeleton: its 77 bones each whole and 2.8 mm under the skin at least, its sides mirroring to 1.4 mm, and its bare bones (the skull, the jaw, the teeth, the sternum, the clavicles, the kneecaps, the tibias, the ulnas, the hands, the feet, the spine) drawn.
* **Limits:**
  * One-way: muscles never move the bones, and flesh never pushes a body: a ball hits the bones' shapes (the character's fit its mesh, a ragdoll's are 1 cm inside its flesh).
  * Fully active, a belly swells by up to a tenth of its volume (one pass of its fibres and its tets' volumes a substep doesn't settle them); relaxed, it keeps it to 2 %.
  * Where two bones blend (a joint), the pins blend linearly, and lose volume there as linear blend skinning does; the tets give some of it back.
  * The character's bones move as its clips say whatever they meet (its feet don't feel the floor), and only one character's table can be in a scene.
  * The écorché's muscles are sculpted, not anatomy's: their marks are placed by eye on the Y Bot's bones, and its other muscles (the forearm's, the neck's deep ones) are groups. The flesh's few muscles bulge it; the rest move only with the flesh.
  * Its skeleton is stylised the same way: the skull is the mannequin's head 6 mm in (rounder than a skull), the forearm's bones don't cross as it turns, the hand's and foot's bones ride the hand and foot whole (the fingers don't curl), and a bone riding its body can show a gap to the flesh beside it where a joint bends far (the knee, the elbow).
  * The lattice is coarse beside a forearm (3.5 cm across one 9 cm thick): its fibres are few there, and a finer lattice costs as above.

### Liquids

Water, blood and honey, simulated on the GPU as particles (`PhysicsFluid.swift`, `PhysicsFluidGPU.swift`, `Shaders/Fluid.metal`), with the same steps on the CPU as their reference (`PhysicsFluidCPU.swift`), drawn as a surface made again every frame (`FluidSurface.swift`, `Shaders/FluidSurface.metal`) and shaded as a refracting, absorbing liquid (`Shaders/Liquid.metal`). The **Fluids** scene (`METALRENDERER_SCENE=fluids`, `Scene+Fluids.swift`) is a tray of three lanes on the studio floor, one a liquid: each is poured from a pipe above three stone steps at the lane's back, runs down them and fills a basin. Over each basin two boxes are held up and dropped once the liquid is there (a box on the floor as the liquid rose round it couldn't float: nothing gets under it), a light one (250 kg/m³) at 4 s that floats and a heavy one (2000 kg/m³) at 5 s that sinks, slowly in honey; a heavy box on the middle step is in the flow's way, and a wooden paddle lies in front of each lane, to grab with the mouse and stir with. It shares the physics scene's look and `physics`.

The scene list's keys are `liquid=all|water|blood|honey` (one lane alone), `solver=auto|pbf|mpm` (every liquid's; `auto` takes `water=pbf`, `blood=pbf` and `honey=mpm`, each `pbf|mpm`) and `fluid=32768`, the most particles a liquid pours (1024 to 262,144).

* **The liquids** (`LiquidKind`): water (1000 kg/m³, 1 mPa·s), blood (1060 kg/m³, shear-thinning: Carreau's model, 56 mPa·s at rest down to 3.45 when it flows fast) and honey (1420 kg/m³, 10 Pa·s), each with its walls' friction and stickiness, its pour (a 3 to 3.5 cm nozzle at 0.8 to 1.4 m/s) and its look: an index of refraction (1.333, 1.36, 1.49) and an absorption per metre in red, green and blue (water's 2, 0.35, 0.12; blood's 35, 600, 800; honey's 2, 9, 45), so a liquid's colour is how deep it is.
* **Two solvers**, either for any liquid:
  * **PBF** (position-based fluids, Macklin and Müller 2013), particles 1.2 cm apart and a kernel 2.4 cm wide: a substep (one a group, below) predicts where they go, sorts them by cell, lists each one's neighbours (those within 1.1 kernel widths, at most 64, in cell order), then 4 Jacobi iterations of the density constraint (with the artificial pressure that keeps them from clumping, and the walls' and the colliders' share of the density, Akinci et al. 2012, so a particle at a wall isn't short of neighbours), velocities from how far they went, vorticity confinement and XSPH viscosity (honey's strong, with stickiness at the walls). Under rest density a particle pulls its neighbours back a little (5 %), which keeps a thin stream in one piece.
  * **MLS-MPM** (Hu et al. 2018), particles 1 cm apart on a 1 cm grid, 3 substeps a group: particles to grid (with APIC's affine momentum, a Tait pressure from how dense the grid says each is, and the viscous stress, Carreau's for blood), the grid's velocities against the walls, the static colliders and the bodies (nodes inside one count as liquid at rest, so the density stays right beside them), then grid to particles. It holds honey's viscosity, which PBF's XSPH only imitates, and is the default for honey.
* **Integers, so the runs are the same.** The grid's mass and momentum, the impulses on the bodies and the surface's splat are added as fixed-point integers (atomics on floats would add in any order); PBF's neighbours come from a counting sort whose cells keep the order the particles had. Two runs of the GPU are bit-identical, and its first steps match the CPU's to 1e-6 m (after that the flow is chaotic: they part). MPM's particles go to the grid by blocks of 4x4x4 cells (Gao et al. 2018): sorted by block, a threadgroup a block adds its particles' parts in threadgroup memory, then into the grid. With three MPM liquids of 32k particles that halved the "physics" pass (36 ms to 17.5) against every particle adding its 27 nodes' parts to the grid itself (the atomics on a node collided), and the integers are the same.
* **With the bodies, both ways.** The liquid takes a step's 4 contact groups (1/240 s each) one at a time, before each group's narrow phase: it sees the bodies where they are, pushes out of them (and off the walls) and gives each the impulse it took, which the bodies take before their substeps (`fluidApply`: at most 2 m/s a group; it wakes a sleeping body only if that is more than 3 cm/s). Buoyancy and drag are what the pushes add up to. A body held up for a drop waits for it whatever splashes it.
* **The surface**: each particle splats its weight on a grid a particle's spacing apart (trilinear), a [1 4 6 4 1] blur along each axis smooths it, and surface nets put a vertex in each cell the level 0.28 crosses and a quad across each edge it crosses, placed by prefix sums of the cells' counts, so the mesh comes out the same every time (and the same as the CPU's). The mesh has fixed room (a vertex a particle, 32k at least, and twice as many triangles); what it doesn't use is degenerate. Its acceleration structure is built again every frame (`.preferFastBuild`) over as many triangles as it last needed (read back a few frames late) and a fifth more.
* **Shading.** The liquid's instances have a mask of their own, so nothing but the liquid's own rays sees them. In the hybrid renderer a pass ahead of the trace (`liquidKernel`) follows each pixel's camera ray through the liquid: at up to 4 crossings it refracts (Snell, Fresnel exactly, total internal reflection), absorbs along the way (Beer-Lambert) and adds the first surface's reflection (the sky and lights' highlights); the trace then starts from where the ray leaves the liquid, so what is seen through it gets the full G-buffer, direct light, denoisers and upscaler, and a pass after the glass multiplies in what the liquid let through and adds the reflection. The reference path tracer treats it as a dielectric with an inside (a ray in the liquid absorbs as it goes), and its shadow rays pass through it, losing what each crossing reflects and what the liquid absorbs.
* **What it costs** (M1 Max, the scene at the physics look, 1440×900; `METALRENDERER_BENCH=fluids`). The first 5 s pour 14,700 particles of water, 7,700 of blood and 12,000 of honey; from 12 s, the larger caps have filled:

  | Setting (particles: water, blood, honey) | "physics" pass (GPU) | "blas" (the surfaces' structures) | Whole frame (GPU) |
  |---|---|---|---|
  | The first 5 s (14,663, 7,714, 12,025) | 5.9 ms | 4.4 ms | 15.0 ms |
  | From 12 s, 16k a liquid (16,384 each) | 9.6 ms | 5.1 ms | 19.6 ms |
  | From 12 s, 32k (32,768, 27,436, 32,768) | 14.6 ms | 5.3 ms | 23.6 ms |
  | From 12 s, 64k (52,204, 27,436, 42,735) | 17.5 ms | 5.6 ms | 26.5 ms |

  Paused, the scene renders in 4.9 ms: the surfaces and their structures are made again only while the liquids move (and for 4 frames after). Moving, the "physics" pass is the liquids' steps but for the surfaces' meshing (0.5 ms) and the bodies' (0.8 ms). The three liquids' steps run side by side, in a concurrent encoder with a barrier between one step and the next (on the M1 Max a dispatch takes about 20 µs however few particles it has, mostly waiting for the one before: one liquid after another, the 270 a frame took 6 ms; side by side, the first 5 s went from 11.5 ms to 5.9). Stepped on the CPU instead, 2,048 particles a liquid take 207 ms a frame on the render thread.
* **Checked:** `FluidTests` covers the pour (a function of the clock, starting in the stream), PBF water and every MPM liquid staying in its box and settling, Carreau's thinning, and on the GPU: the first steps against the CPU (1e-5 m after one, 1e-4 after three, and after 30 the same centre to 1 cm and spread to 3 mm), two runs bit-identical, a reset starting again, the surface against the CPU's (identical, closed: every edge as often one way as the other), a light box floating in water, blood and honey (PBF) and honey (MPM), a heavy box sinking in water and more slowly in honey, and on the CPU the liquid pushing a box back.
* **Limits:**
  * The liquids don't mix: each has its own lane's box, and stays in it.
  * MPM water and blood are lively: a light box floating on them rocks harder and harder (the liquid's push lags the box's motion), and water splashes higher than its surface has room for; so water and blood default to PBF.
  * No surface tension beyond PBF's pull under rest density: thin streams break into drops, and the surface is blobby at 1.2 cm.
  * Shadow and GI rays pass the liquid by (no caustics, and no shadow under it), refraction is sharp (no rough refraction), and wet surfaces don't darken.
  * With liquids the raster's visibility buffer is off (its first hit would be the liquid's), and a frame takes at most 20 steps: a still at 6 s catches up over its first frames, so the GPU's watchdog never sees seconds of steps in one command buffer.
  * Stepped on the CPU (`physics=cpu`), the liquids aren't drawn: their particles stay on the CPU (it is the GPU's reference, and slow).
  * Metal 4 is untested (the M1 Max has no Metal 4 ray tracing).

### Particles

GPU particle effects as modern engines run them (Niagara, VFX Graph), but **ray traced**: their particles show in the camera's view, in reflections and in shadows (`Particles.swift`, `ParticlesGPU.swift`, `Shaders/Particles.metal`, `Shaders/ParticleTrace.metal`), with the same steps on the CPU as their reference (`ParticlesCPU.swift`). The **Particles** scene (`METALRENDERER_SCENE=particles`, `Scene+Particles.swift`) is a dark studio with a glossy floor:
* a brazier's fire (flames, and a flickering light in them), the heat haze over it, and its smoke carried up the fire's column of hot air (`ParticleField.plume`: drawn in low down, spread out high up), as the haze is;
* a grinder's wheel throwing sparks off its rim where a steel bar is pressed on it (a hot glow at the contact), sparks that bounce off the floor, a crate and whatever else they meet, leaving puffs of smoke where they die;
* a swirl of magic motes in curl noise round a plinth, and wisps trailing glowing ribbons through it;
* rain on the right under a lamp in the ceiling (a spot light): lit along its fall, splashing in the pool of light where it lands;
* bursts of rubble on the left: stone chunks (mesh particles, real geometry) that tumble, bounce off the floor, the crate, the brazier and the plinth, and kick up dust that a little whirl of air carries.

The showcase's motes (embers, bubbles, dust, runes) are particle effects too. The scene's keys:
* `budget=1`: every emitter's rate, bursts and pool times this (0.25 to 4);
* `particleshadows=1`, `particlereflections=1`;
* the view's `particlescale=1`: the camera's layer at the traced size, or 0.5 for half.

* **An emitter** (`ParticleEmitter`) holds:
  * where particles are born (a point, a sphere or its surface, a disc, a box, a ring), how many (a rate, and bursts that can repeat), how long they live and how fast they leave;
  * the forces on them: gravity's share, drag toward the air, the scene's wind, **curl noise** (analytic, or the baked tile), a vortex and a pull toward a point, and a **vector field** (`ParticleField`: a grid of velocities it follows or accelerations; `ParticleField.vortex` is a rising whirl);
  * what they bounce off, as a ball of `collisionRadius`: the system's planes, spheres and boxes; **SDF shapes** (`ParticleCollider.shape`: an instance of one of the scene's SDF shapes, by its distance and gradient); and with `collidesWithScene` the scene's own geometry, by a ray along each step;
  * how they look: size and three colour keys over their life, a flipbook, emitted light or lit, an orientation, spin, soft distance, whether they cast shadows; or a **mesh** (`mesh`) instead of a billboard; and a **trail** (`trail`).

  A **child** emitter spawns `perEvent` particles where its parent's die or collide, with a share of their velocity (`trigger`).
* **The step** (1/60 s, counted from the start, as the physics') is three dispatches, and the CPU never reads a count back:
  * **begin** (one SIMD group, a thread an emitter): what each asks for (its rate's births over the step less those before, so a fraction carries; its bursts; or its parent's events), clamped to its dead count; its pops off its **dead list** (a stack of its free slots); the indirect arguments for the next two.
  * **emit** (a thread a newborn): its slot from the dead list (no atomics: begin knows each emitter's top), its birth from its seed (its emitter's and its spawn id's hash: a particle is the same whatever slot it has), moved and aged by a random share of the step so a stream has no layers; appended to the **alive list**.
  * **simulate** (a thread an alive particle): aged (the dead pushed back on their emitter's dead list, and an event written if it has children), the forces, `exp(-drag dt)` toward the air, semi-implicit Euler, the colliders (bounce and friction); the survivors appended to the other alive list with one atomic a SIMD group, which the next step reads. A trail's particle writes its place into its ring every few steps.
  * **Curl noise** is the curl of three channels of gradient noise with their analytic derivatives (Quilez's quintic "noised"), so the flow is divergence-free: particles swirl without bunching. The **baked** tile (`bakedCurl`) is the same curl from noise whose lattice repeats, 32^3 nodes read trilinearly: one read for 24 gradient hashes, and the same statistics, though not the same plume.
* **What rays meet.** After the steps a pose pass packs the alive particles' records (centre, size, axis and spin, colour, flipbook frames) and **boxes** at the front of each structure's range. The CPU bounds how many can be alive (each emitter's births within its longest life, children's through their parents': the counts telescope, so any window is two evaluations), and the builds take only that many.
  * Two primitive acceleration structures of boxes are built every frame (`.preferFastBuild`): the shadow casters' and the others'.
  * The trails' ribbons are a third: **flat Catmull-Rom curves** (Metal's curves that face the ray), a ring of a particle's places and its head, tapering to nothing and fading along it.
  * All of them are separate from the scene's TLAS, so nothing else pays for them, and the particle queries run only to the opaque hit.
  * Nothing is committed: the queries' loops take each box and work out the **billboard** the ray sees in it (a disc square to the ray, a quad along the velocity or an axis turned to face it, or one fixed in the world), so a particle is the same shape to camera, shadow and reflection rays, which a camera-facing quad isn't.
  * **Mesh particles** are instances the scene reserves, a pool slot each, posed every frame ahead of the TLAS update (a frame behind the billboards, whose steps trace the TLAS); a dead one is shrunk to nothing at its emitter. Their own collision rays pass their own instance.
* **Flipbooks** (`ParticleTextures.swift`: dot, smoke, flame, spark, streak, ring, rune, bubble, 8 x 8 frames of 64 pixels each) are generated at load and cached; a box is trimmed to how far its kind's pictures reach. After them come three aux layers:
  * smoke's **six-way light maps**: how much of a light from the right, left, top, bottom, front and behind its puff passes on, by its own density;
  * smoke's and flame's **motion** from a frame to the next, from the generator's own drift, which the camera's frame blending follows, so a lick doesn't cross-fade into a ghost of itself.
* **Translucency per ray, not a sort.** A raster particle system sorts its quads back to front (a bitonic sort) to blend them; here each ray orders its own: a **k-buffer** of the 4 nearest fragments (sorted by distance; past that the two farthest merge, as MLAB does) blended front to back. Exact, and independent of the traversal's order, up to 4; bounded past it.
* **The camera's layer** (`particleLayerKernel`, after the fog) has **soft particles** exactly (each fades over its soft distance in front of the opaque hit) and a near-camera fade, and is fogged at the particles' distance. Without upscaling the composite puts it over the scene.
  * Upscaled, it goes over MetalFX's output (`particleOverlayKernel`), not in as MetalFX's transparency overlay: that filters the overlay over time with the scene's motion, and moving sparks, motes and rain came out as faint grey streaks.
  * Billboards are at least half a layer texel wide (their opacity scaled down to match), so a spark thinner than a texel isn't hit by one ray and missed by the next.
  * Particles still too thin for the layer (under 2 texels) are left out of it and flagged. The overlay traces those pixels again at the output's size: crisp sparks, rain and motes, moving or not.
  * The rest is upsampled with a B-spline, each texel weighed by how near its surface's depth is (no bleeding across edges). `particlescale=0.5` halves the layer.
* **Light.** Emissive particles (fire, sparks, motes, wisps) send their colour; lit ones (smoke, rain, dust) are lit once a particle a frame (`particleLightKernel`).
  * The light comes from each of the first 8 lights, scattered isotropically (E / 4 pi per unit albedo), through the opaque scene and the shadow-casting particles between, plus the sky's mean, averaged over the frames.
  * Through the particles, an octave sum of weaker extinctions (Wrenninge's multiple-scattering approximation) lets a dense column pass on more than single scattering would.
  * The brightest light is kept apart: **six-way smoke** takes it through the maps of the directions it comes from (in the billboard's own frame) and the rest through their mean, so a dense puff is dark on its far side and glows lit from behind. Reflections take the isotropic answer.
* **Heat haze** (`ParticleEmitter.distortion`): distortion particles, simulated like any others but never drawn. Their slots sit apart from the billboards', so no structure, shadow, reflection or light pass sees them.
  * After the overlay (or the composite) and before the lens, `particleDistortKernel` bends each camera ray that crosses them in front of its surface. The bend is up to the emitter's strength (radians) times each disc's opacity over life, (1 - r^2)^2 across it.
  * Its direction is curl noise rising through the air where they are met, across the ray. The pixel reads the frame's light where the bent ray looks, unless the surface there is nearer than the haze, which keeps foreground edges out.
  * A prepass gathers the discs and the part of the view they cover; every pixel outside it is a copy (0.24 ms in all at 1920×1200, about 0.07 ms of it the copy). Bloom and depth of field take the bent light.
* **Shadows and reflections.** A shadow ray (`isVisibleBlocker`) that misses the geometry takes the product of (1 - opacity) of the casters it crosses (any order) and gets through with that chance; the denoisers and averages make it soft, as the voxels' stochastic leaves are. A caster's `shadowDensity` scales what it blocks (a billboard stands for a soft volume: at full opacity a column of smoke shadowed itself black). Reflection rays gather the particles and trails in front of what they reflect (a k-buffer of 2). Mesh particles are geometry: they shadow and reflect as any does.
* **The reference path tracer** stops a path at a particle or a trail's ribbon with the chance of its opacity (the nearest that does): an emissive one adds its light and ends it, a lit one scatters (isotropic, next-event estimation as the fog's), and the emitters before it add theirs. That is the layer's composite on average, so it checks the real-time image: the two agree on the fire, the sparks and their reflections. The smoke is brighter in it: there the flames light it, and light scatters on inside the column.
* **Checked:** `ParticleTests` (22) covers:
  * what an emitter asks for: a rate of 30 a second never two in a step, 270 over 9 s; bursts on their steps;
  * the pool: every slot alive or on its emitter's dead list, once, for 240 steps on the CPU and on the GPU; births past the budget dropped; a distortion emitter's slots apart from the billboards' and never posed;
  * children where their parents die, and splashes on the floor;
  * the noise's analytic gradient against differences, curl noise's divergence, fields read exactly at their nodes (and linear ones exactly between), the baked tile repeating and matching its curl;
  * the GPU against the CPU, with a vector field and the baked curl: the same particles alive, positions within 2e-7 m after 10 steps and 1.5e-5 after 120; with colliders and children, the same counts per emitter;
  * two GPU runs and a reset, bit-identical;
  * the alive bound holding at every step (slack 0 at times: it is tight);
  * the pose packing every alive particle once, frame after frame;
  * every posed billboard inside its box in each orientation;
  * mesh particles' instances (place, size, turn, last frame's place, the normal matrix, the descriptor);
  * trails' control points (places a stride of flight apart, oldest first, tapering);
  * the k-buffer (exact up to 4, order-free), the flipbooks (inside their trims, nothing on a cell's border);
  * a frame's reset, steps and pose each keeping their own parameters.

  Scenes without particles render bit-identically (the feature is a shader specialisation, `PARTICLES`, bit 17).
* What it costs (M1 Max: no ray-tracing hardware, so every box and curve is the shader's work; 640×400 traced, MetalFX 3x, 1920×1200 out; `METALRENDERER_BENCH=particles`). The scene's pools hold 7,040 billboards, 90 trails and 120 chunks (the table is from before the rain's lamp and its denser rain, which made the paused frame 15.3 ms and the moving one 17.4 ms; the fire's heat haze then 15.6 ms paused, the moving frame the same):

  | Setting | Build | Light pass | Camera layer | Overlay | Trace (its shadow rays) | Reflections | Whole frame (GPU) |
  |---|---|---|---|---|---|---|---|
  | Paused at 5 s | — | 0.56 ms | 0.96 ms | 1.28 ms | 2.25 ms | 4.50 ms | 14.6 ms |
  | No particle shadows | — | 0.11 ms | 1.09 ms | 1.23 ms | 1.13 ms | 2.73 ms | 11.3 ms |
  | Not in reflections | — | 0.56 ms | 0.96 ms | 1.28 ms | 2.25 ms | 2.39 ms | 12.5 ms |
  | Half-size layer | — | 0.57 ms | 0.78 ms | 1.73 ms | 2.27 ms | 4.74 ms | 14.8 ms |
  | Moving, a quarter | 1.15 ms | 0.14 ms | 0.34 ms | 0.61 ms | 1.41 ms | 2.15 ms | 10.5 ms |
  | Moving | 1.71 ms | 0.44 ms | 1.05 ms | 1.45 ms | 2.24 ms | 4.45 ms | 16.6 ms |
  | Moving, 4x | 3.17 ms | 1.50 ms | 5.60 ms | 9.26 ms | 5.45 ms | 13.51 ms | 46.7 ms |

  The steps themselves are under 0.2 ms; the mesh particles' pose 0.01 ms. Without particles the trace is 0.86 ms and the reflections 0.83: particle shadows cost most, then the reflections' gather. The overlay grows with the screen thin particles cover: at 4x, sparks and rain over most of it are traced again at 1920×1200. The build is the boxes' (about 1 ms for the bounded counts) and the trails' curves (0.7 ms for 1,260 segments). Paused, a slot's structures stay as they were built, unless the camera moves (the boxes hold the billboards as its rays widen them). Crowded particles cost the most: a dust of 2,000 big puffs where the rubble lands made the 4x frame 70 ms, each ray through it meeting hundreds of boxes; it holds 160 now.
* **Limits:**
  * Particles don't light the scene or each other (no particle lights): fire is lit by a light placed in it, and smoke over it is darker than the path tracer's.
  * GI rays and the virtual shadow maps' traced shadows don't see billboards or trails; glass and liquids don't bend the rays that see them. Trails cast no shadows.
  * Past 4 fragments a pixel the k-buffer merges the farthest; the path tracer is exact.
  * The CPU reference has no scene, so `collidesWithScene` and SDF shape colliders are the GPU's alone; children spawn exactly only while their pool has room (past that, which parents' events win is the GPU's order).
  * Mesh particles are a frame behind; every trail emitter keeps the same number of places.
  * The heat haze is a screen-space bend: it can only show what the frame has. It is undone where the bent ray looks at something nearer than the haze. Reflections and the path tracer don't see it, and without MetalFX it needs the lens (it runs on post's input).
  * Metal 4 is untested (the M1 Max has no Metal 4 ray tracing); the builds (boxes and curves) go into the frame's own encoder there (`PrimitiveWork4`).

### Geometry debug views

The View popup and key 9 cycle six views of what the primary rays hit. They run as a separate pass (about 2 ms at 1280×800) only while shown, so normal frames don't pay for them. Colours are shaded by the facing ratio so shapes stay readable.

| View | Shows |
|---|---|
| Triangles | A random colour per triangle, for all geometry. Virtual triangles keep their colour when the cut's BLAS is rebuilt. |
| Clusters | A random colour per virtual-geometry cluster (up to 128 triangles); other geometry is grey. |
| Groups | A random colour per cluster group, the unit the DAG simplifies and streams. |
| LOD level | The cluster's DAG level on a blue (finest) to red (coarse) scale: finer near the camera, coarser far away. Generated plants: blue where their triangles are traced, green, orange and red for the three voxel levels. |
| Triangle size | Projected edge length in traced pixels: blue ⅛ px, green 1 px, red 8 px and more. Virtual geometry at the default error is mostly green-yellow; full-detail meshes are blue (sub-pixel triangles). |
| Traversal cost | The candidates (triangles and boxes) Metal's traversal hands each primary ray's query, log scale: blue few, red ~250. Metal can't count its nodes; the candidates are what can be seen of its work. |

The views work in both virtual-geometry runtimes (with virtual geometry off, the clusters, groups and LOD views are grey). In `METALRENDERER_VG_MODE=clusters`, cluster colours follow a cluster's place in the page pool, so they change when it is streamed again.

### Reference rendering

Rendering > Reference (key T) replaces the realtime picture with a converged one, for checking what the scene should look like. Samples are averaged over frames, and the average starts over whenever the picture would change: the camera moves or turns, the field of view or the resolution changes, any setting changes, the shaders are reloaded, the scene is rebuilt, or the scene's clock runs. With animation playing, every frame is a fresh one-sample image; pause (Space) to let it converge. The window title and the panel's stats line show how many samples are in. Upscaling, the lens effects and the denoisers are off while it is on, and it isn't saved between launches.

| Mode | What it averages |
|---|---|
| Accumulated passes | The frame's own passes, raw: path-traced GI (Ref. bounces), exact direct light (ReSTIR's unbiased candidates above 1024 lights), the reflection pass's specular, the fog's reference march. This is what the benchmarks' references are (`METALRENDERER_BENCH=gi`). Its limits are those of the passes: bounces past the first hit are diffuse, window glass gets a fixed ambient light and no refraction, area lights are their analytic irradiance times the visibility of one point, and the averaged light is multiplied by the current frame's albedo, so edges stay aliased. |
| Path traced | One kernel (`Shaders/PathTrace.metal`) traces whole paths from jittered camera rays (anti-aliased), Ref. samples/frame paths per pixel per frame. The same materials as the frame (Lambert + GGX); every bounce can be glossy. Window glass is a thin dielectric (Fresnel-weighted mirror, or straight on with its tint, which shadows take too). The volumetric fog is a participating medium: the same density field (height fog, noise, local volumes, albedo, phase function), met by every ray of the path, which scatters in it as often as it happens to (free-flight sampling), with shadow rays dimmed through it. Next-event estimation samples each light by solid angle, and the bounce rays also meet the lights; multiple importance sampling (power heuristic) combines the two. Up to 32 lights each is weighed at every point; with more, the light tree draws them (MegaLights' tree, the suns apart) and bounce rays meet them at their visible shapes. Emissive meshes are lit by next-event estimation through the diffuse lobe and met by the specular one. The first 6 bounces draw Owen-scrambled Sobol points per pixel (white noise past them; `METALRENDERER_PT_SOBOL=0` for white noise throughout). Russian roulette after 3 bounces; no firefly clamp. |

Path traced's fog fills the scene's bounding sphere, the same bounds the realtime fog dims sunlight in: the sun's and the sky's light is what reaches the scene. It has no far cutoff, no haze and no ambient term (all three stand in for what the realtime fog leaves out); its light comes from the lights and the sky through the fog, scattered as often as it happens to, so it differs from the realtime picture: darker where the ambient term lit it, softer and brighter around lit shafts, and surfaces are lit through it (the realtime fog never dims a lit surface). A preset with no height falloff (the mixed room, the tubes garage, the emissive room) fills the whole sphere evenly, outdoors too: in the mixed room the dusk sun crosses some 40 m of it, and its patch on the floor is a quarter as bright as without fog. Light that gets in only through windows or gaps (the sky seen through the misty hall's windows) is found by bounce and scattered rays alone, so those scenes stay grainy longer. Camera rays see the lights' shapes as the frame does; with more than 32 lights a bounce ray that grazes a sphere light outside its shape's facets misses it. In fog, the first frames after a launch don't count until the fog's noise is made (in both modes). Ref. max samples stops adding samples once that many are in (the fog too). Costs at 640×400 on an M1 Max, one path per pixel and 8 bounces, as upper bounds (measured while another session kept the GPU busy): Cornell 13.6 ms, gallery 13.4, area lights 15.3, the stress hall 50, the emissive room 25, the mixed room 42, the misty hall 44 and the night market 55 (the last four with their fog).

### Denoiser settings

| Setting | Default | Effect |
|---|---|---|
| Shadow denoiser | on | Filters each light's (or light group's) visibility instead of the lit colour (see above). With it off, SVGF filters direct light. |
| Shadow passes | 3 | Edge-aware 3×3 passes over the visibility (steps 1, 2, 4). |
| Separate direct / indirect | on | Filters the two separately. Indirect noise then no longer widens the filter across direct-light shadow edges. It doubles the denoiser's cost (about +0.45 ms at 640×400). |
| Filter passes | 4 (2 with cascades) | SVGF à-trous passes (1–5). Fewer passes give sharper contact shadows and more noise. With cascade GI and the shadow denoiser off, only direct light goes through SVGF, and 2 passes measured the same as 4. The slider sets the count for the selected GI method. |
| Edge tolerance (σ) | 2 | How different in brightness a neighbor can be and still be blended, in standard deviations. Lower is sharper and noisier. |
| History length | 16 frames | Temporal accumulation. Shorter means less lag on moving lights and shadows, and more flicker. |
| Anti-lag | off | Shortens the history where a fast and a slow running average disagree, which happens when the lighting changes. It helps most with long histories. |

## How a frame works

```
CPU    animate what moves or flickers (objects, lights)  ->  write those instances, lights and materials into this
       frame's buffers (triple-buffered; what never changes is written once per buffer)
       instance descriptors: the plants name their variant (phase bucket, leaf share) and carry their lean
       virtual geometry (background thread): Nanite cut per instance -> the cut's triangles gathered -> Metal
       builds a BLAS over them on its own queue, where the cut changed
GPU 0  the scene's structures, ahead of every ray (TraceScene: the TLAS and what hits read, at buffer 1):
       physics: the steps since last frame (bodies' and particles' grids, pairs, contacts, every substep in one
       threadgroup), then the bodies' and particles' instance records and descriptors, and the cloths', soft
       bodies' and strands' vertices -> refit their structures (with the crowd's)
       crowd: crowdPoseKernel + crowdSkinKernel -> refit the pose slots' structures
       wind: plantWindKernel poses the plants' variants -> refit each variant a plant names (an encoder each)
       VG_MODE=clusters: vgCutKernel -> vgBoxesKernel (a world-space box per cluster) -> build their structure
       TLAS: refit; rebuild every 16 frames, or when a descriptor names another structure (a new cut, another
       variant or voxel level); a scene in which nothing moves has one, built with the scene
       textures: map + upload the mip levels last frame's hits asked for (sparse textures), unmap unused ones
    1a regirBuildKernel  many lights: the light grid, per cell (2 levels x 16^3) 32 reservoirs of 8 table draws by
                       luminance toward the cell, from this frame's lights (ReSTIR DI's, GI's, the reflections' and
                       the fog's light samples draw from it)
    1b lightMapKernel  per-light distance maps (radiance cascades, path tracer with light maps)
    1c raster          METALRENDERER_PRIMARY=raster: the visibility buffer (Nanite-style, see below): cull instances
                       (last frame's visible) -> cull 128-triangle chunks -> 1 indirect draw of instance + triangle
                       ids and depth -> depth pyramid -> cull the rest against it -> 2nd draw
    2  traceKernel     primary ray (with the visibility buffer: met with the triangle it drew) -> G-buffer (normal, depth, albedo, emission, motion, world position)
                       direct (up to 4 lights): 1 shadow ray per light (+ per-light visibility and penumbra width)
                       indirect (path traced): cosine-sampled path, NEE at every bounce
                       (lighting is stored without albedo so the denoiser can blur it freely)
    2r pathTraceKernel Reference "Path traced" (replaces everything from 1a to 4): whole paths per pixel into a running
                       mean, then tonemapKernel into the drawable
    2a glassKernel     scenes with window glass: the camera ray against the panes in front of the traced surface ->
                       what comes through them into the albedo, F0 and emission; the first pane's mirror ray,
                       its hit lit by 1 light sample, into the emission
    2c manyLightsKernel more than 4 lights: per light group, pick 1 light by unshadowed light, 1 shadow ray
                       (+ per-group visibility and penumbra width); manyLightsReuseKernel also resamples
                       against last frame's picks (default)
    2e meshLightsKernel emissive meshes: 1 light by its proxy, 1 triangle by emitted power, 1 shadow ray
                       (denoised by SVGF on its own, or added to the direct light without the shadow denoiser)
    2g restirTemporalKernel  ReSTIR DI (default above 256 lights; replaces 2, 2c and 2e's direct light): per chain
                       (4), 8 light-table candidates + the suns resampled by unshadowed luminance, then last
                       frame's reservoir; restirSpatialKernel: neighbours' reservoirs, 1 shadow ray per chain ->
                       diffuse direct light (denoised by SVGF) and direct specular (added by the reflections)
    2b cascades        probes -> trace + merge per cascade (top down) -> SH projection -> resolve
    2h lumen           Lumen GI: the global distance field's dirty bricks -> cards (capture the new, light, radiosity
                       on a budget, combine) -> probes on the G-buffer -> trace (screen pyramid, mesh fields, global
                       field, sky; hits lit from the cards) -> filter -> SH projection -> resolve + temporal
    2d reflectionKernel glTF specular materials: 1 GGX ray per pixel, hit lit by 1 light sample + this frame's
                       diffuse GI on screen; / specular albedo; temporal + 2 a-trous passes
                       (fog: dimmed along the ray, + in-scatter from 1 point with 1 light sample)
    0b sky             atmosphere / image sky: skyMeanKernel (clear-sky mean) -> skyKernel (1/16 of the texels:
                       atmosphere + clouds) -> cloudShadowKernel (256^2 over the ground) -> sky mips
    2f fogInjectKernel fog on: per froxel (8x8 px x 64 slices) 1 point in front of the surfaces, 1 light, 1 shadow
                       ray, blended into last frame's grid; fogIntegrateKernel: in-scatter + transmittance front to back
    3  shadowTemporalKernel  direct light: reproject + clamp per-light visibility, penumbra widths, tile classes
       shadowFilterKernel x3 edge-aware, penumbra-limited 3x3 passes (skips fully lit / shadowed tiles)
    3b temporalKernel  SVGF for indirect light: reproject last frame, reject disocclusions, blend, track variance
                       (cascade indirect light skips the denoiser unless you enable it)
    4  atrousKernel x4 edge-aware wavelet filter (step 1, 2, 4, 8)
    5  compositeKernel exact unshadowed light (diffuse + GGX) x visibility + indirect, x albedo, + reflections x
                       specular albedo + emission -> x fog transmittance + fog in-scatter -> ACES tonemap
                       -> drawable (sRGB format: the GPU encodes), or with upscaling the raw linear light at render resolution
    6  upscale         MetalFX's denoising scaler (in place of 3-4), then tonemapKernel into the drawable
```

**Raster visibility buffer** (`METALRENDERER_PRIMARY=raster`, the panel's "Primary visibility"; `RasterScene.swift`, `Shaders/Raster.metal`). The first step of an Unreal Engine 5-style pipeline: the camera's triangles come from the hardware rasterizer, GPU driven, instead of one traced ray per pixel. Meshes are drawn in chunks of 128 consecutive triangles (a cluster in all but the mesh's own order). Each frame, a compute pass keeps the instances in view that were visible last frame, another culls their chunks against the view (bounds worked out on the GPU once per scene), and one indirect draw writes each pixel's instance id and triangle into an `rg32Uint` target over reversed-Z depth (the cull leaves each drawn instance a 64-byte record, its object-to-clip rows and where its indices and positions are, so a vertex reads that, an index and a position). A hierarchical-Z pyramid of that depth then tests every other instance and chunk, as Nanite's two-pass occlusion does; what passes is drawn on top, and every instance's verdict is what the next frame starts from. `traceKernel` meets its unchanged primary ray with the drawn triangle (a ray–triangle test, not the depth), so the distance, barycentrics, motion vectors and everything after them are the ones a traced ray gives, bar a few pixels on triangle edges. What isn't drawn has its bounding box drawn instead, and the pixels where the box is in front trace their primary ray: an assembly's parts, leaf cards (alpha tested), swaying ground cover (it leans where the rays meet it), virtual geometry in the clusters mode, and an instance of more than 4096 triangles with more than 4 per pixel its bounds cover (there is no level of detail to draw it at: a far crowd, baked plants; past that the traced pixels cost less than the triangles). A box that reaches the camera is drawn in front of everything. Only when the draw lists are full does every primary ray trace as well. Far plants as voxel boxes keep traced primary rays. The view "Visibility buffer" shows the chunks in colours, magenta where the primary rays traced what wasn't drawn; `METALRENDERER_BENCH=raster` renders each scene both ways, and that view. On an M1 Max (the custom tracer, since removed; whole frame, `METALRENDERER_BENCH=shot METALRENDERER_BENCH_SPLIT=0`, three alternating rounds) a frame took, traced → raster: stress 10.93 → 10.57 ms, gallery 13.54 → 13.35, crowd 10.96 → 10.19, city 7.71 → 7.35, world 13.74 → 13.36; the Cornell box's runs swing between 5.0 and 7.0 ms either way.

**Raster clusters** (`METALRENDERER_RASTER_VG=clusters`, the panel's "Raster virtual geometry", an advanced setting; `RasterClusters.swift`, `VGStreamer.swift`, `Shaders/RasterClusters.metal`). How Nanite draws virtual geometry, on top of the raster visibility buffer: instead of 128-triangle slices of each instance's BLAS over the CPU's cut (the default, culled by instance only), the GPU picks the cut every frame, cluster by cluster, culls every picked cluster and draws it from a page pool of its own that streams in what the cut asks for. The rays keep the per-instance BLAS, at the cut the same rule picks. In the raster's first pass, every virtual instance in view goes through `rasterVGCutKernel`, a thread per cluster group: a group whose coarser version is fine enough is skipped at once, and each of its clusters is kept when it is fine enough itself (its simplification error projects to at most the geometry error, 1 traced pixel) or its finer group isn't resident, which it then asks for. A kept cluster's box is tested against the view and against the last frame's final depth pyramid, seen from where the last frame's camera and the instance were; what passes is drawn at once (a 128-triangle slot of the draw list that says where the cluster's positions and packed triangles are in the pool, so a vertex reads its 8-bit index and its position as directly as a slice's triangle reads its corner), and what the old pyramid hides is held back until the second pass tests it against this frame's (`rasterVGRetestKernel`): Nanite's two-pass occlusion at cluster level, where a wrong guess costs time, never pixels. A pixel's triangle names its cluster's entry in the frame's cluster list (`y` = `0x80000000` \| entry << 7 \| triangle), and the hits read that list (`TraceScene`'s clusters) as they read the clusters mode's selected ones, so `fetchHitVertices` and `surfaceFromHit` work as for a ray that met one. The streaming is the clusters mode's (`VGStreamer`, shared by both): a 512 MB pool (`METALRENDERER_RASTER_VG_POOL`), groups loaded after the groups above them and evicted least recently drawn, roots always there; benchmarks hold their last warm-up frame until nothing is waiting. `METALRENDERER_RASTER_VG=mesh` draws the clusters with mesh shaders instead (a threadgroup a cluster, each vertex transformed once). The cut draws what the BLAS traces, bar the frustum: in the gallery overview, 404k triangles in 3,903 clusters against the BLAS's 409k, settled in 93 MB, of which about 30 clusters wait for the second pass (a showcase model up close: 240); with direct light alone against traced primary rays, 43.3 dB in the overview, 44.7 in a close-up, 38.4 for a showcase model, as the BLAS's slices do within a run's noise; camera moves show no holes. Moving the rays out from a drawn cluster by its error (`METALRENDERER_RASTER_VG_BIAS=1`), against the two cuts' differences, made it worse: 0.7–1.3 dB, as the rays then start past what is close by. On an M1 Max (the custom tracer, since removed; per-pass medians of three alternating rounds, `METALRENDERER_BENCH=rastervg`) the clusters cost more than the slices, as these scenes hide little: the raster pass 0.34 → 0.38 ms in the gallery overview (mesh shaders 0.48), 0.42 → 0.43 in the close-up (0.53), 0.11 → 0.18 for a showcase model (0.29), plus 0.04 ms for the cut and 0.04 for the second pyramid; a frame 14.5 → 14.6 ms (14.8), 19.9 → 20.2 (20.3), 14.1 → 14.2 (14.3). Reading a cluster's vertex through its list entry and its header (three dependent reads more than a slice's) cost only 0.01 ms of that, so the rest is elsewhere; Apple7's mesh shaders don't make up for it either, so the slices stay the camera's default. `VGCutTests` checks the GPU's cut against the CPU's, frame by frame from the roots to a settled pool. Where they pay is the virtual shadow maps, which take them by default whatever the camera draws (the shadow maps' "Virtual geometry as clusters", `METALRENDERER_VSM=clusters=0` for the BLAS; the pool is then the shadow maps' alone with the camera on the BLAS): drawn from the BLAS, a virtual instance's pages are drawn again every frame (its cut may have changed), the whole instance into every page it covers; with the clusters, `vsmVGCutKernel` picks each shadow view's own cut, a thread per (instance, group, active view), by the error in the view's texels rather than the camera's pixels, so a page stays right while the camera moves and is drawn again only when the instance moves or its mesh gets finer groups. In the gallery with its sphere lights mapped (`METALRENDERER_SHADOW_METHOD=vsm`), a still frame takes 29.0 ms from the BLAS (the pages' draw 9.6 ms) and 13.5 ms from the clusters (0.04 ms), less than shadow rays' 14.4; in a camera move 24.2 → 19.5 ms (a showcase model 15.8 → 14.7). With the camera on the BLAS the shadow maps' clusters save the same (pages' draw 18.1 → 0.05 ms, the raster pass that drew next to it 3.9 → 0.4, in three alternating rounds on a GPU another renderer was also using). Against shadow rays the image is within 49 dB (0.2% of the pixels more than 8 levels off; the BLAS's maps 50 dB). The shadow views' cut wants more of the pool: about 390 MB in the gallery, which the 512 MB default holds (256 MB filled and churned: the camera move's pages' draw 3.8 ms against 3.6 at 512 and 3.2 at 1 GB).

**Virtual shadow maps** (`METALRENDERER_SHADOW_METHOD=vsm`, the panel's "Shadows" under Direct light; `VSM.swift`, `Shaders/VSM.metal`). The second step: the camera-visible surfaces' shadows of suns, spot lights and sphere lights come from Unreal-style virtual shadow maps instead of shadow rays. Each mapped light has a huge virtual depth map seen from it, of which only the 128 × 128-texel pages that shadow samples looked at are held, in a pool of physical pages (a `depth32Float` array, a slice a page; 1024 pages, 64 MB by default). A sun has a clipmap of 12 orthographic levels around the camera, 16 m wide at level 0 and doubling, each 16k texels a side; its pages are named by their place in the light's space, so the camera's moves keep them. A spot light has one perspective view over its cone with mips; a sphere light has a cube of six 4k faces with mips. Every frame, ahead of the trace, the pages last frame's samples asked for get physical pages (a GPU free list; pages nobody asked for in 30 frames go back), the instances and chunks in front of the pages to draw are culled with the raster visibility buffer's chunks and records, and one layered render pass clears and draws them, each triangle into its page's slice, at most 256 pages a frame. Drawn pages stay until their light moves or a moving instance's box (where it was, where it is) covers them. A shadow sample marches the same jittered segment toward its point on the light through the map, eight steps, as Unreal's shadow-map ray tracing does, so the shadow denoiser and the composite see what a ray would give them. What the raster can't draw, and the crowd, which would be drawn again every frame, carry an instance-mask bit (`Scene.maskShadowTraced`) and are traced by a ray that meets only them; a sample whose pages aren't ready yet traces the whole ray, so a small pool or budget costs time, not correctness. Bounces, reflections and the fog keep their rays. The view "Virtual shadow pages" shows each pixel's level or mip in a colour, magenta where its page isn't ready; `METALRENDERER_BENCH=vsm` renders the scenes with suns, spots and spheres both ways, that view, and three in motion; against rays, at most 0.9% of the pixels differ by more than 8 levels in all but the city (1.6%, shadows in window recesses) and the forest (8%, as from run to run in its grass). Where a shadow ray of the custom tracer was cheap, it was about even: on an M1 Max (the custom tracer, since removed; `METALRENDERER_BENCH=shot`, per-pass medians of three alternating rounds) the pages' upkeep and draw take 0.07 ms in a still frame, and the shadows' passes go, rays → maps: city trace 1.23 → 0.93 ms, spots' many lights 0.50 → 0.31, Cornell trace 1.26 → 1.15, world 3.40 → 3.30, sun 0.54 → 0.51; slower are the crowd (3.59 → 3.74, its characters traced as well) and the mixed room (1.39 → 1.48: its rect and tube lights keep their rays). A sun that turns or a light that moves has its pages drawn again every frame (the sun scene in motion: 0.23 ms), as do pages a camera move brings in (the city: 0.9 ms).

With radiance cascades, 2b and 3–4 don't depend on each other. The frame then uses one concurrent compute encoder and runs them in lock step, with a barrier after each step: light map + trace + probes, then temporal + the top cascade, each à-trous pass + the next cascade down, and so on. Small dispatches on M1 leave the GPU partly idle, so this overlap saves about 0.2 ms. The path tracer runs in order.

| File | What it holds |
|---|---|
| `Renderer.swift` | Metal setup, scene loading, the frame (its plan, its stages, their encoding), input; the scene's structures' updates each frame (refits, the top-level structure) |
| `Pipelines.swift` | The shader compile and every compute pipeline as one set, built in parallel off the main thread; the big kernels' variants with a configuration's flags compiled in |
| `TraceScene.swift` | The scene as every ray-tracing kernel gets it at buffer 1 (`TraceSceneArgs`, one per frame slot): the top-level structure by resource ID, virtual geometry's tables, the plants' parts, the wind, the leaf cards' alpha layers and the mesh arrays their test reads, the `RT_STATS` counters |
| `BVH.swift` | A binned-SAH builder over boxes (Lumen's mesh distance fields, SDF volumes), and the small trees over virtual geometry's clusters, stored in their pages, which the ray queries walk in the clusters mode |
| `Settings.swift` | Every user-adjustable setting, with defaults and ranges |
| `SettingsTable.swift` | Every setting once: its place in the settings, its `METALRENDERER_*` name and its panel row |
| `SettingsPanel.swift` | The Render Settings panel, built from the table |
| `SettingsStore.swift` | Saves and restores the settings between launches |
| `SettingsEnv.swift` | The settings as `METALRENDERER_*` variables, both ways: Copy as Env and the parser, from the table |
| `GPUProfiler.swift` | The Debug window's GPU pass timings (timestamp counters at encoder boundaries) |
| `DebugPanel.swift` | The Debug window: frame graph, pass timings, scene, virtual geometry, textures, memory, the ray queries' counters |
| `LoadActivity.swift` | What loads in the background: loads made of steps, the streams after a scene is in (thread-safe; the loaders report to it) |
| `LoadingOverlay.swift` | The loading overlay over the view (AppKit), refreshed ten times a second while something loads |
| `Upscaler.swift` | MetalFX's denoising scaler and the sub-pixel jitter sequence |
| `RasterScene.swift` | The raster visibility buffer's view of a scene (per-mesh records, chunks, instance ids, visibility) and its targets (depth pyramid, draw lists) |
| `VSM.swift` | Virtual shadow maps: which lights get maps, their views (the sun's clipmap, spot and cube views) written each frame, the page table, the physical pool and the lists that draw it |
| `RadianceCascades.swift` | Radiance cascades: probe textures, radiance atlases, per-frame passes |
| `Lumen.swift` | Lumen GI: the screen probes' textures and history, and the frame's passes (cards, probes, trace, filter, SH, resolve) |
| `LumenCards.swift` | Lumen's surface cache: card sizes, the atlas's allocator, which cards are captured, lit and given radiosity each frame |
| `LumenScene.swift` | Lumen's mesh distance fields for a scene: what each field is baked from, the background bakes and their cache, the brick atlas and the instances' records |
| `LumenGlobalSDF.swift` | Lumen's global distance field: the clipmap's windows around the camera and the bricks to compose each frame |
| `MeshSDFBuilder.swift` | The distance-field bake: sparse bricks with a coarse grid beyond them, signs by flood fill, two-sided surfaces, heightfields |
| `BlueNoise.swift` | Void-and-cluster blue-noise generator, and the tile's cache file |
| `CacheFile.swift` | Where the app keeps what it derives (`~/Library/Caches/MetalRenderer`) and how it writes it; the launch timer |
| `SectionFile.swift` | Cache files of arrays behind a table of sections, and the generated scenes' cache folder (its names, its cap) |
| `Benchmark.swift` | Benchmark mode (`METALRENDERER_BENCH`): a setting of a run (`Config`), the frame clock, timing table and PNG capture |
| `Benchmark+Modes.swift` | The benchmark modes: each one's list of settings |
| `Scene.swift` | The Cornell and gallery scenes: meshes, materials, instances, animation paths; the light types, their poses and visible shapes, shadow-denoiser groups, emissive-mesh lights and the light table; glTF models and their lights |
| `Scene+Stress.swift` | The stress test's building: its zones, props and their paths, fixtures and the lights that ride vehicles, arms and hoists |
| `Scene+Lights.swift` | The six light demo scenes, the Misty hall and the fog volumes, the Open valley, the Night market, and the light-check scene the `lightcheck` benchmark renders |
| `Scene+Forest.swift` | Generated plants in a scene (`Flora`: materials, textures, assemblies and their wind bones) and the Forest |
| `World.swift` | The open world as a function of a seed and a place: ground, cities with their blocks, roads and fields, the roads between cities, where trees and ground cover stand; its day (`Heavens`: the sun, the moon, when the lights come on) |
| `WorldTile.swift` | A tile of the world at a level of detail: its meshes, its trees, its lights, its file |
| `Scene+World.swift` | The Open world scene: the tiles around the camera's, which tile that is, and by night the nearer tiles' lights |
| `SceneBuffers.swift` | A scene on the GPU: its geometry's buffers, its instances' records, Metal's acceleration structures; made off the main thread. `MeshBlock`: a borrowed mesh's buffer, which scenes share. `InstanceBlock`: a group of instances, likewise |
| `Foliage.swift` | The plant generator: recipes, the grower, leaf, card and bough distributors, the plant library |
| `FoliageSpecies.swift` | Each species' recipes, by age, and its boughs' |
| `FoliageMesh.swift` | Stems, leaves, cards and grass as meshes; a plant baked into plain meshes; the mesh checks |
| `FoliageTextures.swift` | Generated textures: bark, leaves, grass, and the leaf cards' pictures and alpha masks |
| `FoliageVoxels.swift` | The plants' voxel grids for the distance level of detail, made from the library's plants |
| `PlantTracing.swift` | The plants in Metal's structures: each assembly's variants (wind phases × leaf shares) by multi-level instancing, the plants' descriptors, the wind's posing and refits; `Wind`, the wind's math on the CPU |
| `SDFShapes.swift`, `SDFVolume.swift`, `SDFBuffers.swift`, `Scene+Shapes.swift` | SDF shapes: their nodes, distances, boxes and surface triangles; meshes baked into distance grids; the shapes on the GPU (and their one-box structures); the SDF shapes scene |
| `Physics.swift`, `PhysicsCollide.swift`, `PhysicsCPU.swift`, `PhysicsGPU.swift`, `Scene+Physics.swift`, `Scene+Ragdolls.swift` | Physics: rigid SDF bodies, joints, particles and cloth (the world, its time and replays); shapes' samples and mass, contacts; the CPU's step (the reference); the GPU's buffers and passes, poses and cloth meshes; the physics scene; ragdolls and their scene |
| `PhysicsHair.swift`, `HairBSDF.swift`, `Scene+Hair.swift`, `Shaders/Hair.metal` | Hair and fur: guide strands (building, the CPU's steps, drawn strands), the hair BSDF on the CPU (tests), the hair scene, the BSDF and the strands' lights |
| `PhysicsSoft.swift`, `Scene+Soft.swift` | Soft bodies: their lattices and drawn surfaces (`SoftModel`), the tets' constraints on the CPU, the soft body scene |
| `PhysicsFlesh.swift`, `PhysicsRig.swift`, `PhysicsSkin.swift`, `Scene+Muscles.swift` | Muscles and skin: kinematic bodies and their pose table, flesh pinned to bones, muscles' fibres and activations (`MuscleSpec`); a character's rig and programme (`CharacterRig`); the sliding skin (`SkinShell`); the muscles scene |
| `MuscleAtlas.swift` | The écorché: a character's skin as a signed distance (`BodySurface`), the marks on its body (`BodyMarks`), its muscles sculpted on it (`MuscleAtlas.muscles`), their mesh and textures |
| `SkeletonAtlas.swift` | The écorché's skeleton: its bones built from the rig's joints out of round cones, ellipsoids and plates, their meshes and the grid of their distance the muscles are carved from |
| `VoxelGrids.swift`, `VoxelLOD.swift` | The grids as one-box structures per level, and a still scene's far baked plants' levels, picked as the camera moves and built into another instance structure in the background |
| `Terrain.swift` | The forest's ground: a noise heightfield, as a mesh and as a height function |
| `LightTable.swift` | Every light and emissive triangle as one alias table by power (ReSTIR DI's candidates; GI with many lights) |
| `FogNoise.swift` | The fog's tiling 3D density noise |
| `Atmosphere.swift` | The atmosphere's constants and sun transmittance on the CPU (the sun light's colour); HDR sky images, with their sun found and cut out |
| `FBXReader.swift` | Binary FBX: a memory-mapped reader that skips what isn't asked for and inflates arrays in place |
| `SkinnedCharacter.swift` | Characters and clips from FBX (skeleton, skin, retargeting, levels of detail), posing and skinning on the CPU, the cache file |
| `Crowd.swift` | The crowd's pose slots: what each plays at a time, and where its walkers are |
| `CrowdSkinner.swift` | The crowd's GPU buffers and per-frame dispatches, and the check against the CPU |
| `Scene+Crowd.swift` | The Crowd scene |
| `Scene+City.swift` | The City scenes: the streets, the buildings' meshes and materials, the sun or the moon |
| `CityPlan.swift` | The city's layout from its settings: street grid, districts, lots, lamps and trees, viewpoints |
| `Building.swift` | The building generator: what to build, a building's parts, plans (`Footprint`), tiers and massing, the detail limit |
| `Building+Facade.swift` | The facade grammar: storeys, bays, and the window, balcony, door, shop and loading-door tiles |
| `Building+Roof.swift` | Flat, gabled, hipped and mansard roofs, chimneys, and what stands on a flat roof |
| `BuildingStyle.swift` | The five styles: proportions, pieces and palettes a building draws from |
| `MeshBuilder.swift` | Quads, boxes, prisms, cylinders and balls with texture coordinates in metres, for generated meshes |
| `ProceduralTextures.swift` | The city's generated tiling textures and their cache files |
| `Showcase.swift` | The showcase's looks: per model of `Assets/`, its set, colours, particles, fog and lens; finding a model by name |
| `Scene+Showcase.swift` | The showcase scene: the model on its plinth, the rig, the seven sets, the particles, the camera framed from the model |
| `GLTFLoader.swift` | glTF 2.0 (`.glb` / `.gltf`) parsing: accessors, node hierarchy, metallic-roughness materials, images, punctual lights |
| `MaterialTextures.swift` | Whole textures, decoded at a capped size (when streaming is off or unsupported) |
| `TextureStreamer.swift` | Texture streaming: mip-chain caches, sparse textures, feedback, mapping and uploads |
| `MeshClusterizer.swift` | Clusters (≤128 triangles) by region growing, and cluster groups |
| `MeshSimplifier.swift` | Quadric half-edge-collapse simplifier with locked borders and seam-aware attribute handling |
| `VirtualGeometryBuilder.swift` | The cluster LOD DAG, cluster pages and the cache file format |
| `VirtualTracing.swift` | Virtual geometry in the top-level structure: the virtual instances' descriptors, each naming its cut's BLAS, or the clusters mode's one instance over its boxes |
| `VirtualBLAS.swift` | Virtual geometry at run time (default): the cut per instance on the CPU, its triangles gathered, and Metal's BLAS built over them on a queue of its own |
| `VirtualGeometry.swift` | The GPU-driven variant (`METALRENDERER_VG_MODE=clusters`): the GPU cut, and the cut's clusters as world-space boxes for a structure built every frame |
| `VGStreamer.swift` | Virtual geometry's streaming: the page pool, the residency table, requests, loads and evictions (both GPU cuts') |
| `RasterClusters.swift` | The raster visibility buffer's virtual geometry as clusters (`METALRENDERER_RASTER_VG=clusters`): its pool, cut tables, cluster list |
| `GPUTypes.swift` | Structs shared with the shaders. Their layout must match `Shaders/Types.metal` |
| `ShaderSource.swift` | Joins the shader files into the one source the runtime compiler takes, with `#line` markers so a compile error names the file and line |
| `Shaders.metal` | The shaders' entry file: the header and the list of pieces, in the order they build on each other |
| `Shaders/*.metal` | All GPU code, one file per subject: `Types`, `Sampling`, `Intersect`, `Surface`, `Lights`, `Regir`, `LightSampling`, `Fog`, `Sky`, `Trace`, `Glass`, `RestirDI`, `RestirGI`, `Reflections`, `Denoise`, `Output`, `Post` (the lens and the finish), `RadianceCascades`, `LumenSDF` (the fields: sampling, tracing, the global field's composition), `LumenCards` (the surface cache), `Lumen` (probes, traces, filter, resolve), `VirtualGeometry`, `Foliage` (the wind, and posing the plants' variants), `Crowd` |

## Notes for M1 / M2 Macs

M1 and M2 have no ray tracing hardware, so Metal's intersector runs in software, and the ray budget is the main cost here. Until October 2026 this project's own BVH traversal beat it by 19–24% in the stress test (see "Removing the custom tracer" below). On M3 and later it runs in hardware: see "Hardware ray tracing, MetalFX's denoiser and Metal 4" below. Metal 4 with ray tracing needs M3 or later: on M1 and M2 the renderer stays on Metal 3.

* By default the frame is traced at 0.5× the window size in points and upscaled 3× (1280×800 points → 640×400 traced → 1920×1200). Press `-` or `=` to change the traced resolution, and **U** to change the upscale factor.
* MetalFX temporal upscaling works on M1. With path-traced GI, the default resolution setting costs about 6.0 ms of GPU time on an M1 Max (custom upscaler), against 43 ms for a native 1920×1200 frame and 11.5 ms for a 960×600 frame stretched to the window. The stretched frame matches or loses to the upscaled one on image quality. If the GPU or system doesn't support the MetalFX denoiser, the app renders at 0.75× without upscaling.
* With radiance-cascade GI (the default), the default frame costs about 2.4–2.8 ms with the custom upscaler (2.5 ms while the camera moves), against 3.0–3.1 ms with MetalFX. Only direct light goes through a denoiser in this mode.
* **Where the default frame's time goes** (M1 Max, per pass, serialized): upscaler 0.6 ms (0.7 while the camera moves; MetalFX takes 0.7–1.3 ms plus a 0.04 ms copy), trace 0.71, radiance cascades 0.61 (probes 0.07, trace 0.43, SH 0.01, resolve 0.11), shadow denoiser 0.25 (temporal 0.17, 3 filter passes 0.08), light map 0.10, composite 0.05, TLAS refit 0.04.
* **Shadow denoiser vs SVGF on direct light** (640×400, PSNR against a 4096-frame reference, `METALRENDERER_BENCH=shadow`):

  | | Static | Contact crop | Flicker | Moving | Camera move | GPU ms |
  |---|---|---|---|---|---|---|
  | SVGF (16-frame history) | 47.5 dB | 42.6 dB | 0.15 | 30.2 dB | 30.0 dB | 0.32 (RC mode) / 1.07 (4 passes) |
  | Shadow denoiser | **48.9 dB** | **43.0 dB** | 0.15 | **43.9 dB** | **43.1 dB** | **0.25** |

  SVGF's long history smears moving shadows, because motion vectors move surfaces, not shadows. The shadow denoiser's clamp fixes that, and filtering visibility rather than colour keeps the shading sharp.
* **Upscalers** (PSNR against supersampled native 1920×1200 frames, `METALRENDERER_BENCH=upscale`; "pan" = camera move over the frozen scene):

  | 3× from 640×400 | Albedo static | Flicker | Albedo moving | Camera move | Pan | Direct static | Direct moving | Pass |
  |---|---|---|---|---|---|---|---|---|
  | MetalFX temporal | 47.5 dB | 0.36 | 45.1 dB | 43.1 dB | **43.4 dB** | 42.7 dB | 38.7 dB | 0.7–1.3 ms + 0.04 copy |
  | Custom (TAAU) | **51.7 dB** | **0.05** | **45.8 dB** | **43.3 dB** | 43.2 dB | **43.6 dB** | **38.8 dB** | **0.6–0.7 ms** |
  | MetalFX spatial | 39.3 dB | 0.00 | 39.3 dB | 39.3 dB | 39.3 dB | 37.5 dB | 36.8 dB | ~0.3 ms + copy |

  | Custom vs MetalFX at other factors | Albedo static | Flicker | Albedo moving | Camera move | Pan | Direct static | Direct moving |
  |---|---|---|---|---|---|---|---|
  | 2× from 960×600 | +5.0 dB | 0.06 vs 0.23 | +0.8 dB | −0.4 dB | −0.4 dB | +0.8 dB | −0.2 dB |
  | 1.5× from 1280×800 | +4.5 dB | 0.09 vs 0.26 | +0.6 dB | −0.1 dB | −0.7 dB | +1.3 dB | +0.2 dB |

  The custom upscaler collects its own sharp samples over the jitter cycle, so still images converge to near-supersampled quality without MetalFX's shimmer. Motion took three fixes, each found by measuring:
  * **Lanczos-3 history resampling.** Re-sampling a moving history every frame blurs it a little each time. A 1D simulation of the upscaler showed Lanczos-3 leaves under half the edge error of Catmull-Rom. It costs 36 taps, so it's used only where the neighbourhood has detail; flat areas keep the 5-tap Catmull-Rom.
  * **A gentle motion cut, with a hard one at depth edges.** History is now kept through camera motion, except next to depth edges, where camera translation uncovers background (parallax) that the colour box can't tell from history.
  * **Dilation within about one input pixel.** Taking the closest surface's motion over the whole 3×3 dragged the foreground's motion 4–5 output pixels into the background. That background then fetched stale history and left trails behind edges.

  At 2× and 1.5× it still trails MetalFX by up to 0.7 dB in camera moves.
* **Comparing the GI methods** on an M1 Max, at the default setting (640×400 traced → MetalFX 3× → 1920×1200). PSNR is measured against the 8-bounce path-traced references (higher is better); GPU times are whole frames (`METALRENDERER_BENCH_SPLIT=0`) from short benchmark runs.

  | GI method | GPU ms | Static | Contact crop | Indirect only | Moving | Camera move | Flicker |
  |---|---|---|---|---|---|---|---|
  | Path traced, 2 bounces | 6.4 | 25.7 dB | 24.4 dB | 21.1 dB | 25.6 dB | 25.5 dB | 0.30 |
  | Path traced + light maps | 5.0 | 25.6 dB | 24.3 dB | 21.1 dB | 25.6 dB | 25.5 dB | 0.31 |
  | Radiance cascades | **3.0** | 36.1 dB | **34.7 dB** | 31.1 dB | 36.1 dB | 36.1 dB | **0.05** |
  | Radiance cascades, 4 px probes | 3.7 | **36.6 dB** | **34.8 dB** | **31.5 dB** | **36.6 dB** | **36.6 dB** | 0.05 |

  ReSTIR GI, measured later with the custom upscaler, scores 42.2 dB static and 38.8 dB indirect here (see "Indirect light (ReSTIR GI)").

  The path tracer's large error is mostly missing energy: in this white room, light keeps bouncing well past 2 bounces. Its image reaches only about 88% of the reference's brightness, while radiance cascades get multi-bounce light almost for free.
  * **Radiance cascades** have no temporal accumulation, so they follow moving lights best and barely flicker. Their probes are interpolated across edges, though, which can show as thin light or dark streaks along object edges.
  * All quality columns are measured on 640×400 frames without MetalFX.
* **Stress test** (M1 Max, radiance cascades and the custom upscaler 3× from 640×400 unless noted; whole-frame GPU ms, best of two `METALRENDERER_BENCH=stress` runs with `METALRENDERER_BENCH_SPLIT=0`). "Before" is one shadow ray per light with the TLAS rebuilt every 256 frames; the next row adds the 16-frame rebuild; "now" adds light sampling with reuse and the lighter spheres. All of these were measured with Metal's acceleration structures, before the custom ray tracer came (it took 1.9–3 ms off the busier rows until it was removed; see "The custom tracer against Metal's" below):

  | 400 objects | 1 light | 4 | 8 | 16 | 32 | 64 | 128 | 256 |
  |---|---|---|---|---|---|---|---|---|
  | Before | 5.3 | 7.6 | 10.1 | 17.3 | 33.3 | 49.0 | 90.4 | 190.1 |
  | + TLAS rebuild every 16 frames | 3.6 | 5.8 | 8.0 | 12.7 | 21.9 | 42.3 | 83.5 | 167.7 |
  | **Now** | **3.5** | **5.5** | **6.3** | **7.3** | **8.1** | **8.9** | **9.9** | **11.7** |

  | 32 lights | 0 objects | 100 | 400 | 1000 | 2000 | Path traced (400) |
  |---|---|---|---|---|---|---|
  | Before | 6.6 | 19.4 | 33.3 | 29.3 | 30.9 | 50.3 |
  | **Now** | **3.3** | **5.2** | **8.1** | **11.1** | **12.6** | **16.3** |

  * **The TLAS was degrading.** A refit keeps the tree built for where the objects were, and with 400 objects moving freely, rays got 35% slower over 256 frames of refits. Rebuilding every 16 frames traces as fast as rebuilding every frame, for the refit's median cost.
  * **Shadow rays no longer grow with the light count.** Choosing each pixel's lights still weighs every light, but that's arithmetic, not rays. It runs in its own kernel (`manyLightsKernel`): inside `traceKernel`, whose register use limits occupancy, the same loop cost 4× as much. The remaining growth from 8 to 256 lights is that loop (about 2 ms), the composite's loop over all lights (0.8 ms at 256) and the light maps.
  * **Merging static objects into one acceleration structure didn't help.** Baking every unmoving object into one mesh (one instance instead of one each) made rays about 25% slower: walls and pillars lose their tight, flat instance boxes, which the top-level tree culls cheaply, and their big triangles split badly inside one tree. Merging only the small static clutter was within noise (−0.5 to +0.2 ms over 400–2000 objects), so it isn't used. What did help: the stress scene's small spheres use 320 triangles instead of 1280, which traces 5–6% faster and looks the same at their size.
  * **Quality** (direct light only, 640×400, PSNR against references that trace every light for 1024 frames, `METALRENDERER_BENCH=stressq`, scored by `Tools/eval/stress.py`):

    | | 32 lights static | moving | flicker | 128 lights static | moving | flicker |
    |---|---|---|---|---|---|---|
    | One ray per light + shadow denoiser | 37.5 dB | 34.8 dB | 0.15 | 39.9 dB | 36.8 dB | 0.10 |
    | 1 ray per group + shadow denoiser | 37.5 dB | **35.6 dB** | 1.05 | 38.1 dB | 37.2 dB | 1.45 |
    | **1 ray per group + reuse (default)** | 36.7 dB | 35.3 dB | 0.72 | 37.4 dB | 37.2 dB | 0.94 |
    | 2 rays per group + shadow denoiser | **37.9 dB** | 35.5 dB | 0.52 | **39.9 dB** | **37.8 dB** | 0.66 |
    | 1 ray per group + SVGF | 35.4 dB | 29.2 dB | 0.36 | 37.0 dB | 30.6 dB | 0.37 |

    Sampled lights match tracing every light in motion and come close on still frames, but each group's visibility is now a fraction estimated from one 0/1 sample, so still frames flicker more. Two rays per group halve that, for about 4 ms. Reusing light picks (ReSTIR-style temporal resampling, `manyLightsReuseKernel`) cuts it by a third without more rays, for about 0.7 dB on still frames and 0.7 ms: each pick already follows the unshadowed light exactly, so reuse can't improve the distribution, but a pixel's pick no longer changes every frame. These lost:
    * ReSTIR's "visibility reuse" (dropping occluded picks, so reservoirs drift toward visible lights) cut flicker as much but darkened penumbrae and lagged: −3 dB still, −5 dB moving.
    * Weighing a random subset of 32 lights instead of all of them under-represents each pixel's brightest light: −7 dB at 128 lights.
    * Widening the shadow denoiser's history clamp lowers flicker but costs 2 dB everywhere.
    * **Vectors in place of arrays and run-time vector indices, where a loop over the lights surrounds them** (bit-identical images; whole frame, stress hall, 32 / 256 / 1024 lights):
      * `manyLightsKernel` kept each ray's pick in small arrays indexed by the ray, inside the loop over the lights. As the lanes of `float2` / `uint2` with `select`: −0.06 / −0.40 / −1.53 ms with one ray and no reuse, −0.03 / −0.89 / −3.47 ms with two rays.
      * The composite multiplied every light by `vis[its group]`. As `dot(vis, groupMask(group))` its pass is 7–12% cheaper; with the same for `manyLightsReuseKernel`'s per-group reads and writes, the default frame is −0.12 / −0.25 / −0.46 ms. (Walking each group's range of lights instead, with the visibility hoisted, gained only a third of that.)
      * The same changes did nothing where no such loop surrounds them: the trace kernel's per-light sums (exact lights) and GI's 4 cached light picks (`lightIllumCached`, whose 4-sample loop the compiler already unrolls).
      * ReSTIR's spatial kernels keep up to 8 neighbours' surfaces and reservoirs in arrays (about 1 KB per thread). Keeping only the neighbours' pixels and reading them again in the MIS loop was slower: ReSTIR DI +0.23 ms in the stress hall and +0.10 ms in the market, ReSTIR GI's spatial pass +11%. Halving the arrays changed nothing for ReSTIR GI. The arrays aren't what those kernels wait for.
  * **GI methods in the stress scene** (32 lights, 640×400, against an 8-bounce path-traced reference; GPU ms are whole frames at the default 3× upscaling):

    | | GPU ms | Static | Contact crop | Flicker | Moving | Camera move |
    |---|---|---|---|---|---|---|
    | **Radiance cascades (default)** | **8.1** | 25.5 dB | 28.0 dB | 0.79 | 25.3 dB | 25.3 dB |
    | Radiance cascades, 4 px probes | — | 27.4 dB | 29.9 dB | 0.69 | 27.1 dB | 27.1 dB |
    | Path traced, 2 bounces | 16.3 | **32.5 dB** | **35.0 dB** | **0.65** | **31.2 dB** | **31.2 dB** |

    ReSTIR GI scores 36.4 dB static and 35.8 dB moving here (see "Indirect light (ReSTIR GI)"). Radiance cascades, the best choice in the Cornell room, lose 7 dB to the path tracer here: their probes sit on a screen grid and are interpolated across the edges of hundreds of small objects. (Surfel GI, since removed, scored about 35.6 dB here for 10 ms.) Sampled lights cost the GI nothing: every method scores within 0.15 dB of its score with every light traced, and the path tracer gains 0.9 dB.
  * **Upscalers in the stress scene** (3× from 640×400, against supersampled 1920×1200 frames):

    | | Albedo static | Flicker | Albedo moving | Camera move | Direct static | Direct moving |
    |---|---|---|---|---|---|---|
    | Custom (TAAU) | **43.2 dB** | 0.96 | **35.7 dB** | **35.3 dB** | 35.1 dB | 31.4 dB |
    | MetalFX temporal | 41.8 dB | **0.33** | 34.9 dB | 34.7 dB | **35.6 dB** | **31.8 dB** |

    The custom upscaler stays sharper and better in motion, but on a still frame full of small objects it flickers three times as much as MetalFX (on the Cornell room it was 0.05). Objects narrower than an input pixel show up only in some jitter phases, so the colour clip, which trusts the current frame, removes them and they pop back later. Turning off the clip's history cut removes the flicker (0.21) but costs 1.2 dB static and 0.9 dB moving; dead zones and a min/max hull test traded the two without winning. MetalFX and FSR 2 protect such pixels with thin-feature "locks", which this upscaler doesn't have yet.
* **Kernel variants: a configuration's flags compiled in.** The big kernels ask the same questions every frame: are there specular materials, is this the path tracer or does a GI technique follow, is the sky a texture, is this ReSTIR pass the one that shades, do reflections follow whole paths. As tests of a uniform, both answers stay in the kernel. The renderer now makes a variant of the kernel for the answers in use, with them as Metal function constants (`flagOn` / `passOn` in `Shaders.metal`; `Kernel.fixedFlags` and `KernelVariants` in `Pipelines.swift`).
  * A variant is compiled in the background the first time a frame asks for it (about 0.3 s each, then Metal's shader cache has it). Until it is ready the frame runs the kernel's general pipeline, which reads the same flags from its uniforms, so changing a setting never stalls. Benchmarks wait for the variant instead.
  * Whole frames (`METALRENDERER_BENCH_SPLIT=0`, M1 Max, medians of 3 alternating rounds, `METALRENDERER_VARIANTS=0` against the default):

    | | General | Variants | |
    |---|---|---|---|
    | Cornell room, default | 2.87 ms | 2.84 ms | −1% |
    | Cornell room, path traced | 8.55 | 8.38 | −2% |
    | Cornell room, ReSTIR GI | 7.82 | 7.64 | −2% |
    | Stress hall, 32 lights, 400 objects | 8.85 | 8.58 | −3% |
    | Stress hall, 2000 objects | 13.12 | 12.65 | −4% |
    | Stress hall, path traced | 19.12 | 18.22 | −5% |
    | Misty hall, fog off (960×600) | 10.41 | 10.13 | −3% |
    | Emissive panels, fog (960×600) | 13.44 | 12.91 | −4% |
    | Spot lights, fog, 3× upscaled | 4.21 | 3.92 | −7% |
    | Night market, ReSTIR, 4096 bulbs | 19.19 | **17.77** | **−7%** |

  * What mattered is taking a ray cast out of a kernel, not the test itself:

    | Pass (per-pass timing) | What its variant leaves out | General | Variant |
    |---|---|---|---|
    | Trace, a technique does the GI and more than 4 lights (market, stress hall) | the bounce loop and the per-light shadow rays: only the primary ray is left | 0.94 ms | **0.71 ms** (−24%) |
    | Trace, path traced, more than 4 lights (stress hall) | the per-light shadow rays (the many-lights pass casts its own) | 12.09 | 11.36 (−6%) |
    | Trace, path traced, up to 4 lights (Cornell room) | nothing but a few tests | 6.95 | 6.80 (−2%) |
    | ReSTIR DI, 4096 bulbs | the temporal pass's visibility ray (off by default), the shading in passes that only merge | 10.44 | 9.58 (−8%) |
    | Reflections (emissive panels, fog) | the second bounce that only references follow | 6.21 | 5.77 (−7%) |
    | ReSTIR GI initial, 1 bounce | the second ray and the feedback lookup | 2.00 | 1.74 (−13%) |
    | ReSTIR GI initial, 2 bounces (default) | nothing but a few tests | 5.10 | 5.00 (−2%) |
    | Fog injection, many lights | the sky and blue-noise tests | 0.99 / 4.70 | 0.94 / 4.67 |

  * What didn't help: variants for flags that only guard a texture read or a clamp. ReSTIR GI's spatial pass, the cascades' trace and the mesh-light pass measured 0–1%, so they have none. A compiled-in bounce count for the path tracer measured the same as the uniform's.
  * The variants render what the general pipelines render: with `METALRENDERER_MATH=safe` (no reordering of arithmetic) all 225 images of ten benchmark suites match bit for bit with variants on and off (`stressq`, `restirq`, `restircheck`, `restirgicheck`, `marketq`, `gi`, `quality`, `lightcheck`, `fogcheck`, `skycheck`), and the general pipelines render exactly what the code before this change rendered (87 images of `stressq` and `gi`). Under the default fast math the two differ by rounding: at most 1 of 255 levels on most images, RMS about 0.005, plus a few pixels where a stochastic pick flipped.
* **Shader helpers instead of copies** (October 2026). The kernels had grown the same code in several places; it now lives in one helper each (the list, with where each is, is in `.claude/skills/performance/references/gpu-metal.md`, section 9):
  * the scene bundle a kernel builds from its bindings (12 copies; the kernels that only evaluate lights no longer bind geometry, and the fog kernels and the cascades' probe kernel lost bindings they never read), the sample stream's setup (7), the firefly clamp (6), the bounce direction mirrored above the triangle (4);
  * a point on an emissive triangle (4), the streaming weighted pick (6), the grid / table / sun candidate of an RIS loop (2 of 3: ReSTIR DI's draws its numbers in another order);
  * "is this the same surface?" with named tolerances, last frame's pixel of a pixel (3), the pixel that shows a path's hit (3), the disk neighbour and the pairwise MIS weights of the two spatial reuse passes, the edge-stopping weights of the two à-trous filters, the Karras split of the two tree builders (both since removed with the custom tracer).

  The helpers compute what the copies computed: with `METALRENDERER_MATH=safe` on both sides, all 224 images of eight benchmark suites (`stressq`, `restirq`, `gi`, `fog`, `marketq`, `speccheck`, `restirgicheck`, `vgdebug`) match the previous commit's bit for bit. Whole frames, three alternating rounds against the previous commit, median change over a mode's settings:

  | Mode | Settings | Median change | Range |
  |---|---|---|---|
  | `restir` | 22 | −0.01 ms | within the noise of the cascades' resolve pass |
  | `stress` | 15 | +0.02 ms | −0.03 … +0.35 ms |
  | `fog` | 43 | +0.01 ms | −0.24 … +0.14 ms |
  | `gi` | 36 | +0.03 ms | −0.09 … +0.30 ms |

  * In `gi`, the full-budget ReSTIR GI settings are 0.10–0.15 ms (1.2–1.9%) slower and the high-quality cascades 0.03 ms (1%), in every round. No helper accounts for it: putting any one back by hand, or all of a kernel's, leaves the frame within ±0.1 ms of where it was, forcing the helpers inline makes it slower (+0.21 ms), and the previous commit's shaders with one never-taken extra call in a kernel the benchmark doesn't even run are slower by the same 0.1 ms (1.2%). The helper files alone, with the old kernels, cost nothing (0.00 ms). So this is how the compiler's module-wide decisions fall for a given source, not a cost of a helper: expect any shader edit to move unrelated kernels by about 1%, and judge a change of that size against a control edit (`measuring.md`).
  * Left different on purpose, because making them alike changes images: next-event estimation at a path's hit (the path tracer, ReSTIR GI and the reflections take their branches in different orders; the cascades' and the path tracer's light-map branch draw 8 candidates and clamp, the others 4 and don't), the ambient fixed point (1024 in the cascades, 256 in ReSTIR GI), and a light sample's distance floor (1e-6 at surfaces, 1e-4 in fog). The two bottom-up fit kernels kept their own walk-up loops (device-scope fences around a coherent pointer); both went with the custom tracer.
* **Load time: the glTF parser and the BVH builder** (October 2026; M1 Max, the gallery's 11 models, 17.9M triangles):

  | Step | Before | After |
  |---|---|---|
  | Models parsed, virtual geometry on (the default) | 0.4 s | 0.2 s |
  | Models parsed, virtual geometry off | 0.7 s | 0.4 s |
  | The custom tracer's BLAS (since removed), virtual geometry off (9.7M nodes) | 2.1 s | 1.5 s |

  * The parser reads 32-bit float positions, normals and texture coordinates straight into their vectors (no intermediate array, no type test per component), and the index type is tested once, not per index.
  * The builder bins a node's primitives along the three axes in one pass instead of three (the trees: 1.6 s to 1.3 s), and each mesh's nodes are written to their own range of the node buffer in parallel (0.36 s to 0.12 s). The parallel loops that took a lock to store a result write to their own slot instead.
  * The BLAS was the same, byte for byte (a checksum of its nodes, triangles and roots against the old builder's), and the custom tracer's brute-force check found no mismatch in 50000 rays.
  * A range of more than 32768 primitives now builds its two halves at the same time, and `BVHTests` checks that the tree is the single-thread one, node for node (the builder now serves the distance fields and the clusters' trees). It doesn't show in the gallery, whose eleven meshes already keep every core busy; it is there for one big mesh (not measured yet).
  * What didn't help, and is not in the code: an exact split for nodes of up to 12 primitives without the bins (the same tree, the same 1.5 s). Keeping the boxes in tree order, so a node reads a contiguous range, measured the same as reading them through the index array.
  * Metal now builds the meshes' structures; the custom tracer's BLAS, 1.5 s of a 2 s load with virtual geometry off, went with it.

* **Per-frame CPU: what a frame repeats** (October 2026; M1 Max, each measured with a timer around the code itself, in µs per frame over 100 frames, since the benchmark's `cpu` column moves by 0.1–0.2 ms from run to run):

  | Change | Where | Before | After |
  |---|---|---|---|
  | The scene's resources are declared once per encoder, not at every dispatch that traces | Night market, ReSTIR, 11 scene binds per frame | 34 µs | 18 µs |
  | Clusters mode's page table is copied to a frame slot only when it changed, the resident count is kept instead of recounted, and nothing is sorted when nothing was requested | gallery, `METALRENDERER_VG_MODE=clusters`, 40104 groups, settled view | 50 µs | 1.2 µs |

  * What a bind still costs is its ten `setBuffer` calls: those stay, because the kernels in between use the same indices for their own buffers.
  * What didn't help: one staging buffer per frame slot and one pair of encoders per frame for the texture streamer's uploads, in place of a buffer and two encoders per texture. The streamer's CPU time over a gallery run (49 MB uploaded in 234 levels) was 9.4 ms before and 9.9 ms after, so it kept its simple form.
  * Threadgroup sizes are now looked up by `Kernel` instead of by a name string (too small to measure: a tidier table). `METALRENDERER_TG` names a kernel by its `Kernel` case, capitals and spaces aside (`trace=16x8`, `restir gi initial=8x8`).
  * Images are unchanged (`stressq`, `marketq`, `vgdebug`). In clusters mode 12 of `vgdebug`'s 18 views can be compared: the triangle and cluster colourings and the traversal cost there follow the order the GPU hands out cluster slots in, and differ between two runs of the same build.

* **Small GPU items that measured nothing** (October 2026). Seven ideas from the code audit, each tried as a copy of the shaders against the current ones with the same binary (`METALRENDERER_SHADERS`), whole frames, five alternating rounds (the same shaders against themselves: 0.00–0.02 ms). None is in the code:

  | Idea | Tried | Whole frame |
  |---|---|---|
  | A smaller traversal stack (the custom tracer's) | 48 and 128 entries instead of 64 | ±0.03 ms (stress hall, 8.6–18.3 ms frames) |
  | | 32 entries | +1.8 to +3.5 ms: 20% slower |
  | Trace's writes that a later pass overwrites | no indirect write with the cascades or ReSTIR GI, no direct write with ReSTIR | −0.01 ms (cascades), ±0.05 ms (ReSTIR) |
  | The sky's ambient light, computed once | a constant in place of the two sky samples (the most it could save) | 0.00 ± 0.01 ms (fog scenes) |
  | One atomic add per SIMD group | `simd_sum` in the cascades' SH pass, instead of four adds per probe | 0.00 ± 0.02 ms |
  | The filters' normal weight | 6 or 7 squarings in place of `pow(x, 64)` and `pow(x, 128)` | −0.10 to +0.27 ms, no pattern |
  | The filters' colour sums in `half` | à-trous and the shadow filter | −0.06 to +0.02 ms |
  | The temporal pass's fallback for new pixels | removed (the most a cheaper one could save) | 0.00 to +0.06 ms |

  * The stack's result is the one worth remembering: 64 entries cost nothing over 48, and below some size the compiler handles the array differently and every ray pays. What the audit was right about is that a full stack skips a subtree silently, so the custom tracer's counters counted those pushes, until it was removed. No scene had any: the stress hall, the market at 16384 bulbs, and the gallery in each of its three geometry modes.
  * The per-pass columns suggested gains the frame didn't have (the SH pass read 0.06–0.11 ms faster with `simd_sum`): when passes are timed apart, a pass's time includes how it sits between its neighbours.
  * ReSTIR GI frames came out 0.10–0.12 ms faster without trace's indirect write, and the path-traced ones 0.27 ms slower with the squarings: both are the frame's two states (see the shader helpers' note), which an edit flips, not the edit's own cost.
  * Not tried: one atomic per SIMD group in virtual geometry's cut. The cut and its tree build together are 0.3 ms of a 20–37 ms frame, in the non-default clusters mode.

* **Launch: the first frame after a quarter of a second** (October 2026; M1 Max, time from the process's start, the line `Launch: …` the app prints):

  | | Window | First frame |
  |---|---|---|
  | Before | 0.17 s | 1.15 s |
  | After | 0.15 s | 0.24 s |
  | Before, after a shader edit | 2.66 s | 3.65 s |
  | After, after a shader edit | 0.15 s | 2.80 s |

  * The blue-noise tile took 0.5 s to generate inside the first frame, on every launch. It is now read from a cache file (64 KB); on the very first launch it is generated in the background, and until it is in, sampling is white noise through the general pipelines (so no kernel variant is compiled for those frames).
  * The settings panel takes 0.35 s to lay out. It is now built after the first frame instead of before it.
  * The shaders compile in the background (`startCompilingShaders`): the window is up at once, and the scene, the textures and the noise are prepared meanwhile. Metal's cache makes that 2 ms on an ordinary launch; after a shader edit it is 1.9 s for the source and 0.6 s for the pipelines, which is what is left of the 2.8 s. A failed compile no longer stops the app.
  * The fog's noise (50 ms) and an HDR sky image (a few hundred ms to decode) are made in the background too: the fog appears a few frames late, the sky shows its constant colour (or the image at its last exposure) until the image is in. Benchmarks do all of this up front, so their frames are the same as before (`quick`, `stressq`, `skycheck`, `fogcheck`: identical images).

* **Direct specular was counted twice with the shadow denoiser** (fixed October 2026). With the shadow denoiser, the composite adds the analytic lights' direct specular (exact GGX × the denoised visibility), and the reflection pass is meant to leave it out. But only the composite's uniforms carried the shadow-denoiser flag, so the reflection pass kept adding its own sample of the same light: highlights of lights on glossy surfaces came out too bright, and the pass cast a shadow ray per pixel for it. The flag now reaches every kernel of the frame. `METALRENDERER_BENCH=speccheck` (direct light only, against an accumulated reference, `Tools/eval/specular.py`):

  | Shadow denoiser path | Brightness / reference | PSNR |
  |---|---|---|
  | Studio (area lights) | 1.04 → **1.00** | 39.2 → **50.8 dB** |
  | Stage (spot lights) | 1.02 → **1.00** | 43.9 → **46.8 dB** |
  | Garage (tube lights) | 1.05 → **1.00** | 38.9 → **49.9 dB** |

  The gallery close-up gains 0.1 dB with cascades, 0.5 dB path traced and 1.1 dB with ReSTIR GI. Without the extra ray the reflection pass is 11–33% faster where lights are analytic: whole frames 10.08 → 9.28 ms in the Misty hall (fog off, 960×600), 6.83 → 6.01 ms in the garage and 3.93 → 3.75 ms on the stage (3× upscaled, fog), measured after the variants table above. ReSTIR and SVGF direct light were not affected, and scenes without specular materials render bit for bit as before.
* **Highlights were dark without the shadow denoiser** (SVGF on direct light, or no denoiser; fixed October 2026). There the reflection pass adds the lights' direct specular from one sampled light. It picked that light by its *diffuse* light at the pixel, so a light with a strong highlight but little diffuse light there had a small pdf, its samples came out several times too bright, and the pass's firefly clamp cut them: the highlights lost energy, and what was left was noisy. Now the light is picked by its specular light (`pickLightSpecular`), and the sample is that analytic specular × the shadow ray's visibility, which is what the composite adds with the shadow denoiser. A sample can't exceed the lights' summed specular, so the direct term is no longer clamped; the clamp stays on the reflection ray's light. `METALRENDERER_BENCH=speccheck`, SVGF path:

  | | Brightness / reference | PSNR |
  |---|---|---|
  | Studio (area lights) | 0.94 → **1.00** | 32.7 → **48.4 dB** |
  | Stage (spot lights) | 0.97 → **1.00** | 40.4 → **45.4 dB** |
  | Garage (tube lights) | 0.98 → **1.00** | 39.9 → **49.3 dB** |

  With `METALRENDERER_DENOISE=shadows=0` the gallery gains 0.2–1.3 dB and its close-ups flicker a quarter less (0.54–0.58 → 0.39–0.47). The pass costs the same (−8% to +4% per scene). References keep the old sampling, exact for spheres and spots, and render bit for bit as before; so does everything with the shadow denoiser.
  * What didn't do as well: only moving the direct specular out of the clamp (44.5, 43.6 and 48.7 dB, with visible fireflies on the stage), or clamping it at 4× like the other direct-light samplers (43.9, 43.3 and 46.6 dB). The pick was the problem; the clamp only showed it.
* **Removing the custom tracer** (October 2026). The project's own BVH traversal, the "custom tracer" (a two-level BVH whose moving instances' top-level tree was rebuilt on the GPU every frame as an LBVH, with the plants' assemblies as a third level), is gone, and with it `METALRENDERER_RT`, `_RT_CHECK`, `_RT_BUILD`, `_VG_BLAS`, `_BLOCK_PART`, the settings panel's "Ray tracing" and the `rt` benchmark mode. Metal's acceleration structures answer every ray query, and what only the custom tracer had now runs on them: virtual geometry (a BLAS per instance over its cut), the plants' assemblies with their wind and leaf fall, and leaf cards. Measured on the M1 Max (software ray tracing), whole frames (`METALRENDERER_BENCH_SPLIT=0`):

  | | Metal's tracer | Custom tracer, before |
  |---|---|---|
  | Gallery, VG 1 px, direct light, still (640×400) | **6.8 ms** | 9.0 ms |
  | Gallery, VG 1 px, cascades, still | **8.3 ms** | 10.3 ms |
  | Gallery, VG 1 px, path traced, close-up | **17.7 ms** | 26.6 ms |
  | Forest, default shot (cascades, 3× from 640×400, wind 0.4) | 53.3 ms | **46.0 ms** |
  | `forestcheck`, assemblies (960×600) | 69.8 ms | **65.6 ms** |
  | `forestcheck`, leaf cards (960×600) | 223 ms | **83 ms** |

  * **Virtual geometry**'s frames are 19–33% shorter on Metal's tracer, which draws the custom tracer's pictures (RMS at most 0.85 of 255 levels, 0.03 on the albedo). Its BLASes, not compacted, take about twice the memory (107 against 53 MB for 418k triangles), and the first, synchronous builds are slower (350 against 50 ms).
  * **The clusters mode** (`METALRENDERER_VG_MODE=clusters`) draws the same pictures (the albedo identical) but takes 43–54 ms a frame against the BLAS mode's 7–8: in software ray tracing every cluster box a ray meets goes back to the shader.
  * **The forest** is 16% slower in the wind: posing the variants and refitting the 232 the plants name is about 11.6 ms of the GPU's frame. Without wind it takes 42.2 ms, and with the plants baked and still, as Metal's tracer had them before, 27.2 ms.
  * **Leaf cards** are 2.7 times as slow: every card triangle a ray meets goes back to the shader for its alpha test.
  * **The open world's start** draws the custom tracer's picture (RMS 0.56 of 255).
  * All of this is the M1 Max's. The M4 Max (hardware ray tracing, and Metal 4's) still has to be measured; there a hand-over to the shader costs differently again (see "Voxels" under "Generated plants").
* **The custom tracer against Metal's**, before the custom tracer was removed (M1 Max, stress scene, 32 lights, moving, custom upscaler 3× from 640×400).
  * Whole frames (`METALRENDERER_BENCH_SPLIT=0`, two alternating runs each):

    | | Metal | Custom |
    |---|---|---|
    | Cornell room, default | 2.40–2.45 ms | 2.34–2.52 ms |
    | Stress, 2000 objects, radiance cascades | 12.59 ms | **9.60 ms** |

  * Per pass (the `rt` benchmark mode, since removed), Metal → custom:

    | Pass | 400 objects | 2000 objects |
    |---|---|---|
    | Path-traced trace (primary ray + 2 bounces + NEE) | 9.40 → **6.72 ms** | 16.41 → **10.65 ms** |
    | Many-light shadow rays | 4.55 → **3.38 ms** | 7.76 → **4.98 ms** |
    | Radiance-cascade trace | 1.37 → **1.21 ms** | 2.41 → **1.80 ms** |
    | Light maps | 0.56 → 0.54 ms | 1.05 → 0.99 ms |
    | Top-level tree | 0.07 → 0.08 ms | 0.08 → 0.12 ms |

  * Quality (`METALRENDERER_BENCH=stressq`): every direct-light, GI and upscaler score is within ±0.2 dB of Metal's.
  * Paused frames differ from Metal's by RMS 0.02–0.3 of an 8-bit level. The few larger differences are soft-shadow pixels where an any-hit shadow ray reports a different occluder, which shifts the penumbra estimate.
  * What mattered, in order:
    * **One loop for both levels.** Nesting the per-instance bottom-level loop inside the top-level loop let SIMD lanes in different levels wait on each other. Merging them (entering an instance pushes a marker and switches the ray to object space; popping the marker switches back) almost halved closest-hit cost: path-traced trace 12.97 → 6.73 ms at 400 objects. Before that, the custom tracer was 35% *slower* than Metal on closest hits.
    * **Static objects stayed instances** in their own tree, built once, as with Metal (merging them into one mesh loses the walls' tight boxes).
    * **Lights that stay in place are static too.** A light says what of its pose changes (`Scene.LightMotion`: animated, scale only, constant), and only an animated light's shape is a moving instance. In the Night market that leaves 140 of 17329 instances in the per-frame tree at 16384 bulbs: the tree build drops from 0.29 to 0.07 ms, the whole frame by 0.30 / 0.38 / 0.62 ms at 1024 / 4096 / 16384 bulbs, and the CPU's work per frame from 0.63 / 0.86 / 1.73 to 0.37 / 0.43 / 0.64 ms (the `cpu` column; the images are bit-identical). The static shapes got their own tree next to the geometry's, under one root: shadow and GI rays skip it there by its mask. One tree over both cost those rays 0.5 ms at 16384 bulbs, because the SAH then splits the geometry around the bulbs.
  * What didn't help:
    * Skipping postponed subtrees that start beyond the closest hit (a second stack of entry distances) cost 15%: the extra stack traffic outweighs the boxes it skips.
    * A smaller stack (32 entries) changed nothing.
    * Bigger leaves (a higher SAH traversal cost) were 2–4% slower.
    * A watertight triangle test (Woop et al.) was 30% slower and changed no image. The upscaled moving frames that differ from Metal's along silhouettes come from depth and motion differing in the last float bits, which the upscaler's depth-edge and clip decisions amplify; native frames match bit for bit.
    * An SAH-built moving-object tree (`METALRENDERER_RT_BUILD=cpu`, since removed) traced only 4–7% faster than the GPU LBVH.
    * Writing the per-frame instance and light records straight into the shared buffers (to skip a copy) cost the GPU 0.35 ms a frame at 16384 moving lights: records written one by one stay in the CPU's caches. The renderer keeps them in arrays of its own, rewrites only what moved, and copies each array to the frame's buffer in one go.
    * Relaxed instead of fast shader math (`METALRENDERER_MATH=relaxed`) renders the same images and costs 0.2 ms a frame in the stress hall, so fast math stays; the shaders test for "no hit" with a comparison (`isFar`) that fast math can't fold away.
* MetalFX's built-in denoiser (`MTLFXTemporalDenoisedScaler`) also runs on an M1 Max under macOS 27, but it costs 4.2 ms at 640×400 → 1920×1200. That's more than this project's SVGF denoiser plus the temporal scaler it would replace (about 1.5 ms together). It is now the only upscaler; the next section has its numbers on an M4 Max.

* **glTF gallery** (11 Tripo models, 17.9M triangles, 67 textures of up to 4096², M1 Max, 640×400; `METALRENDERER_BENCH=gallery`, `Tools/eval/gallery.py`).
  * Virtual geometry against full-detail meshes, same scene, on the custom tracer (since removed; GPU ms per frame; Metal's tracer takes 19–33% less with virtual geometry, see "Removing the custom tracer" above):

    | | Full detail | VG 1 px | VG 2 px |
    |---|---|---|---|
    | Triangles traced | 17.9M | 0.4M (overview), 1.1M (close-up) | 0.18M |
    | Geometry memory | ~1.5 GB (BLAS + vertex buffers) | 40 MB (overview), 108 MB (close-up) | 18 MB |
    | Overview, direct light | 4.33 | 4.09 | 3.81 |
    | Camera fly-through (3× upscaled) | 16.63 | 17.54 | — |

    About the same speed, at 3–4% of the memory (Metal's uncompacted BLASes take about twice the custom tracer's trees). The cut updated in the background in 30–150 ms when it changed (the fly-through rebuilt 900 instance BLASes). Quality: the cut is crack-free and looks the same. Against path-traced references it scores 29.7 dB at 1 px, 31.5 dB at 0.5 px and 35.0 dB at full detail on the overview; the single sample per pixel makes texture detail alias, so sub-pixel geometry changes cost dB there (blurred 4×4, VG 1 px and full detail agree to 41 dB).
  * PBR against the path-traced references (close-up, full detail): 30.8 dB with cascades, 31.6 dB path traced. Average colour per region matches within 0.5% on the glossy floor, 1–3% on the steel plinths, about 5% on the bronze owl. The reflection pass costs 0.4 ms on a still frame and 0.6–1.0 ms in motion.
  * Texture streaming: 14 MB resident from the overview and 46–65 MB close up, against 2.6 GB for all levels (or 711 MB capped at 2048). Images match fully resident 4K textures at 56–77 dB. Uploads are capped at 48 MB per frame.
  * What mattered:
    * **One SAH tree per model over the cut, not a tree of clusters.** The first runtime selected the cut on the GPU, streamed cluster groups into a 768 MB pool (buddy allocator, LRU, Nanite's residency rules) and built a per-frame LBVH over the selected clusters, each with its own little BVH. It works (`METALRENDERER_VG_MODE=clusters`, now a box structure over the cut's clusters, built every frame, whose ray queries walk each cluster's own BVH) but traced 2× slower than full detail on the custom tracer, and is about 6× slower than the BLAS on Metal's in software. Rays visit 8.6 nodes per ray inside models instead of 3.8, because cluster boxes overlap. Splitting the tree per instance to drop the per-cluster transform changed nothing, and an offline SAH over the same clusters would only save 15%.
    * **Simplification that keeps going:** locking only group borders (not the mesh's own open edges), letting seam and border vertices slide along their seams, a relaxed pass across UV seams for fragmented Tripo atlases when the strict one gets stuck, passing stuck groups up a level, and filling clusters spatially. That took the DAG from 883 root groups per model (full-detail fragments, always drawn) to one 366-triangle root, and the cut from 62k clusters to 3.9k.
    * **Texture levels from the largest UV stretch** (as GPUs do) and a histogram instead of a minimum: UV slivers and close self-reflections had asked for 4K mips of models 100 px tall (600 MB resident instead of 14).
  * In close-ups, Metal's intersector on the full-detail meshes was about 12% faster than the custom tracer with virtual geometry (11.1 vs 13.7 ms); from the overview, and in the stress scene, the custom tracer was faster.

## Hardware ray tracing, MetalFX's denoiser and Metal 4

What the GPU and the system can do is checked at launch (`Capabilities.swift`):

* **Ray tracing: Metal** (required: a GPU without it is refused). Metal's acceleration structures and intersector, which M3, A17 Pro and later traverse in hardware, and M1 and M2 in software. Until October 2026 it was an option next to this project's own BVH, the default then. On macOS 26 the per-mesh structures are built for fast intersection (`MTLAccelerationStructureUsage.preferFastIntersection`) and compacted.
* **Upscaler: MetalFX denoiser** (macOS 26; the only upscaler since October 2026). `MTLFXTemporalDenoisedScaler` takes the raw 1-sample light, linear and unbounded, with the albedo, the normals, a specular albedo and the roughness to guide it, and returns it denoised at the output resolution. It stands in for SVGF, the shadow denoiser and the upscaler; `tonemapKernel` then applies the exposure and the tone curve.
* **Graphics API: Metal 4** (`METALRENDERER_API=metal4`, macOS 26). The same kernels through Metal 4's command model (`Metal4Backend.swift`): an `MTL4CommandQueue`, command buffers reused with an allocator per frame slot, one unified compute encoder for dispatches, blits and TLAS updates, bindings through an argument table, a residency set in place of `useResource`, explicit barriers, pipelines from `MTL4Compiler` and MetalFX's Metal 4 scalers. The residency set drops what no frame has declared for 600 frames (and, eight frames after a scene is replaced, what no frame has declared since), so everything a kernel reaches through an argument buffer is declared every frame, the streamed textures included (they are placement-sparse textures, each its own allocation next to the heap). `METALRENDERER_RESIDENCY_LIFE=<frames>` shortens the 600, so that a resource nobody declares shows in a run of a thousand frames (`METALRENDERER_RESIDENCY_LIFE=16 METALRENDERER_SHOT_FRAMES=1000`): the frame that reaches it after it was dropped faults, and the log says which command buffer failed.

Measured on an M4 Max (macOS 26.5, 640×400 traced → 1920×1200, moving frames, rendered into a texture rather than the window's drawables).

**Whole frames**, GPU ms (`METALRENDERER_BENCH=hwrt METALRENDERER_BENCH_SPLIT=0`, two runs within 0.05 ms of each other), measured when the mode still compared the custom BVH (since removed) and three outputs (now only MetalFX's denoiser is left):

| Scene, GI | Output | Custom BVH | Metal (hardware) |
|---|---|---|---|
| Cornell, path traced | SVGF + custom upscaler | 1.93 | **1.31** |
| | SVGF + MetalFX temporal | 2.33 | 1.70 |
| | MetalFX denoiser | 3.04 | 2.41 |
| Cornell, radiance cascades | SVGF + custom upscaler | 1.00 | **0.78** |
| | SVGF + MetalFX temporal | 1.39 | 1.10 |
| | MetalFX denoiser | 2.46 | 2.26 |
| Stress hall (400 objects, 32 lights), path traced | SVGF + custom upscaler | 4.52 | **1.90** |
| | SVGF + MetalFX temporal | 4.94 | 2.29 |
| | MetalFX denoiser | 5.47 | 2.90 |
| Stress hall, radiance cascades | SVGF + custom upscaler | 2.78 | **1.35** |
| | SVGF + MetalFX temporal | 3.19 | 1.69 |
| | MetalFX denoiser | 4.08 | 2.68 |

* **Hardware ray tracing wins everywhere here**: frames are 22–32% shorter in the Cornell room and 51–58% shorter in the stress hall (the trace pass alone: 2.24 → 0.63 ms). On the M1 Max the custom BVH was 19–24% ahead.
* **MetalFX's denoiser costs 1.0–1.5 ms more** than what it replaces: 1.75 ms for its pass with the tone map, against 0.25 ms for the custom upscaler plus about 0.5 ms for SVGF and the shadow denoiser. It also takes 0.2 ms of CPU time per frame to encode (the others: 0.03–0.06 ms).

**Image quality** (`METALRENDERER_BENCH=hwrtq`, `Tools/eval/hwrt.py`, on Metal's tracer; PSNR against supersampled references, flicker in 8-bit levels between two frames of a still scene):

| Scene | Output | Static | Flicker | Moving | Camera move |
|---|---|---|---|---|---|
| Cornell | SVGF + custom upscaler | **38.2 dB** | 0.29 | **36.7 dB** | **36.6 dB** |
| | SVGF + MetalFX temporal | 38.0 dB | **0.25** | **36.7 dB** | 36.6 dB |
| | MetalFX denoiser | 34.6 dB | 1.16 | 32.1 dB | 32.8 dB |
| Stress hall | SVGF + custom upscaler | 35.8 dB | 1.33 | **32.5 dB** | **32.2 dB** |
| | SVGF + MetalFX temporal | **35.9 dB** | **0.31** | 32.4 dB | 32.1 dB |
| | MetalFX denoiser | 30.0 dB | 1.46 | 28.1 dB | 28.3 dB |

* MetalFX's denoiser is 3.4–5.9 dB behind and flickers more on a still frame. Its edges are sharp and well anti-aliased; what it loses is in the shading: soft shadows and smooth walls come out with low-frequency ripples, and fast-moving objects keep some speckle. SVGF's direct light has an advantage it can't have: the shadow denoiser filters visibility only and multiplies it onto exact, unshadowed light.
* Tried for it and scoring the same (within 0.2 dB): a fixed exposure texture instead of auto exposure, and a denoise-strength mask over the sky and the emitters. Its view matrices make no difference at all on macOS 26.5. The jitter's sign, the motion vectors' sign and the reversed depth all matter (1–6 dB when wrong), and match the temporal scaler's.
* Not tried: the specular hit distance and the transparency overlay (fog), which the scenes scored here don't exercise.

**Metal 4 against Metal 3** (`METALRENDERER_BENCH=api`, measured when it still ran both tracers and all three outputs): the frames are bit-identical, for both tracers and all three outputs, in the Cornell room, the stress hall and the scenes with a sky. Whole-frame GPU time is the same within 0.01 ms (0.99 / 0.99, 0.78 / 0.78, 4.49 / 4.49 and 1.93 / 1.94 ms for the four rows of the mode); the CPU's encoding takes 0.01–0.02 ms more. Scenes with a sky cost 0.2 ms more (the valley: 1.53 → 1.77 ms, 1.20 → 1.42 ms with Metal's tracer), for the Metal 3 command buffer in the middle of the frame described below. So Metal 4 buys this renderer nothing yet: its frames were already one compute encoder with few bindings.

What Metal 4 does differently on macOS 26.5, found while matching the images:

* `MTL4ComputeCommandEncoder.generateMipmaps` keeps one texel of each 2×2 instead of their mean, for 2D, array and 3D textures alike (a 0…1 ramp ends in a 1×1 level of 0.98, not 0.49). The sky's mips are its means, so skies came out hazier. Mip generation goes through the Metal 3 queue instead.
* MetalFX's Metal 4 denoising scaler fails an assertion in MPSGraph as it is created (`Incompatible shape for parameter at index 0`) for nearly every size: of 19 tried, only 960×540 and 960×544 to twice that worked. The denoiser stays the Metal 3 one under Metal 4. MetalFX's Metal 4 temporal and spatial scalers work and match.
* Both of those run in a Metal 3 command buffer between two of the frame's Metal 4 ones; each queue waits for the other through an `MTLSharedEvent`.
* Texture streaming: a residency set takes no sparse heap, so the streamed textures are placement sparse on a placement heap. The streamer hands out the heap's tiles and the queue maps them between the frame's command buffers. A placement-sparse texture is not part of its heap: each one is declared every frame, or the residency set lets it go 600 frames after its last upload and the kernels that sample it fault. The Gallery's and the city's benchmark frames match Metal 3's bit for bit.
* Argument-table bindings are captured at each dispatch, so one table serves the whole frame. `MTL4Compiler` takes the same MSL 3.2 source and function constants. Metal 4 requires indirect TLAS instance descriptors (72 bytes, the mesh's structure by resource ID).
* Not there under Metal 4: the settings panel's per-pass GPU timings (they time encoders, and a Metal 4 frame is one).

What didn't help:

* Building the TLAS for fast intersection instead of for a fast build (`METALRENDERER_TLAS_BUILD=fast`): the trace gets 0.04 ms slower in the stress hall with 2000 objects (0.76 → 0.80 ms, in each of three alternating rounds). A default-quality build (`default`) traces the same 0.76 ms. The refit most frames matters more than how the tree was built. (A scene in which nothing moves is another matter: its tree is built once, at default quality, and never refitted, and the open world's 727,000 instances trace 6% faster for it than with a tree built fast.)
* The per-mesh structures' fast-intersection build and compaction (`METALRENDERER_BLAS=default` turns them off) measure the same on the procedural scenes (0.76 ms either way), whose meshes are tiny (0.1 MB of structures). They change which of two coplanar triangles a few rays hit: stills differ by at most 3 levels. The glTF gallery is where they could show.

## Where to go next

1. **Many lights, sharper:** ReSTIR scales flat but stays below the grouped picker's quality up to 1024 lights, because SVGF blurs noisy radiance where the shadow denoiser only blurs visibility. The light grid made the candidates 2.4 dB better in the Night market, but SVGF turns that into 0.3–0.6 dB; a denoiser built for ReSTIR (ReBLUR or ReLAX-style, with the reservoirs' confidence as input) would blur less. The grid's cell target ignores orientation (so it stays unbiased); a conservative cone and facing test over the whole cell would drop the spots and rects that can't reach it, and a per-cell normal estimate from last frame's G-buffer would do better still. With the grouped picker, still frames still flicker more than with one ray per light; a denoiser that tracks the variance of fractional visibility over time is the likelier fix there.
2. **Metal's tracer, everywhere:**
   * Measure the M4 Max (hardware ray tracing, Metal 4's ray tracing): the assemblies, their wind and leaf fall, leaf cards, virtual geometry's BLASes and clusters mode have only been measured in software on the M1 Max.
   * The wind's refits under Metal 3: the variants the plants within the sway reach name, two to an encoder, are 2% of the moving forest's frame on the M1 Max at the default 20 m (a fifth before the reach). Fewer variants named (buckets shared by more plants), or refits spread over frames, would cut it more.
   * Leaf cards: every card triangle goes back to the shader for its alpha test (2.7 times as slow as the custom tracer's in software). Opaque card cores with only the edges alpha tested would hand back fewer.
   * Virtual geometry's BLASes: compaction would halve their memory, and the first, synchronous builds take 350 ms against the custom tracer's 50.
   * With 2000 objects the frame still costs more than with 400; sorting secondary rays by direction for coherence is the thing to try.
3. **Better GI caching:** radiance cascades and ReSTIR GI's multi-bounce feedback fall back to the scene's average indirect light at points no screen pixel covers, and cascades lose 7 dB to the path tracer in cluttered scenes like the stress hall. A coarse world-space irradiance volume (or DDGI probes) would give those points real local values.
4. **Cheaper ReSTIR GI:** its paths cost what the path tracer's do, so it runs at 2–3× the cascades' cost. Half-resolution reservoirs (with full-resolution reuse), or paths that end in a world-space radiance cache after one bounce, would cut that. The multi-bounce feedback alone, which made most of its gain, could also be given to the plain path tracer. And a denoiser that uses the reservoirs' confidence (ReBLUR or ReLAX-style) might turn reuse's lower raw noise into a lower error, which SVGF doesn't.
5. **The crowd, further:**
   * Write the walkers' transforms on the GPU (instance data and Metal's instance descriptors), which is what the CPU still does per character and frame.
   * Metal's tracer pays per refitted structure: refit half the slots a frame, or build the poses' structures with Metal 4's own acceleration-structure encoder where it exists.
   * Pick a pose's level of detail by its nearest character's distance, with full-detail slots for the characters next to the camera.
   * Keep the bots' two materials (a material index per triangle), and read skins and animations from glTF too.
6. **Specular, better:** reflections reproject with surface motion, so glossy reflections smear a little in camera moves (virtual-point reprojection would fix that), and secondary hits treat specular as diffuse.
7. **Virtual geometry:** the cut on the GPU, feeding Metal's BLAS builds, would let the cut update every frame; LOD cross-fades would hide the rare pop; the clusters mode needs hardware ray tracing to be worth it, if then.
8. **Texture compression:** ASTC or BC7 would cut the texture cache (2.5 GB) and streaming bandwidth by 4×.
9. **Unreal Engine 5-style rendering**, after the raster visibility buffer (`METALRENDERER_PRIMARY=raster`), virtual shadow maps (`METALRENDERER_SHADOW_METHOD=vsm`) and Lumen GI (`METALRENDERER_GI=mode=lumen`), in this order:
   * **The visibility buffer, further.** Plants are still traced alongside it (that ray traverses the whole scene, up to the drawn triangle): the instance-mask bit the shadow maps brought (`Scene.maskShadowTraced`) would let it skip the rest, and drawing assemblies and leaf cards (alpha tested in the fragment) would drop it. The crowd draws every triangle of every character in view (no chunk bounds, as they deform): chunk bounds refitted after the skinning would cull them.
   * **Virtual shadow maps, further:** pages marked from the raster's depth ahead of the trace (now a page first seen is traced for a frame); the crowd is traced rather than drawn again every frame (chunk bounds refitted after the skinning, and pages for what moves kept apart from the static ones, as Unreal does, would let it be drawn); rect and tube lights keep their rays.
   * **Lumen, further:** voxel lighting for the global field's hits, so radiosity through the field (Lumen's own way, cheaper outdoors) stops losing the near contact; finer fields for the open world's 256 m tiles (2.2 m voxels now) and fields for its plants (they are in instance blocks the fields don't see); a world that rebuilds keeps its global field, shifted, instead of composing it again; a world-space radiance cache for the long rays.
   * **Nanite's clusters, further** (`METALRENDERER_RASTER_VG=clusters`): a scene that hides much (the clusters' occlusion has little to cull in the gallery) to show where they pay; what else makes a showcase model's clusters cost 0.07 ms more than its slices (not the vertex's reads); shadow pages made stale by the groups that came in (their bounds) rather than by their whole instance; finer level-of-detail tests for the shadow views (a group's error per page, not per view).
   * **A software rasterizer** for pixel-sized triangles, through 64-bit atomics (Apple8 and later, M2 on: not this M1 Max).
   * Upscaling stays MetalFX's denoising scaler: it is the role Unreal's TSR plays.
