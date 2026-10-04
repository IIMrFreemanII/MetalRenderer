# MetalRenderer

A minimal real-time ray tracer for macOS and Metal, with dynamic lights and global illumination.
It's built for Apple Silicon and tuned for an M1 Max.

* **Dynamic scenes:** objects and lights move every frame. Pick a scene in the settings panel:
  * a small Cornell-style room;
  * a **stress test** hall with up to 2000 moving objects and 16384 moving lights (see below);
  * a **Night market** street lit by thousands of festoon bulbs, lanterns, windows and neon signs (see "Many lights" below);
  * the glTF **Gallery**;
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
* **Sky and clouds:** a physically based atmosphere, or an HDR environment image, with the sun.
  * The atmosphere has Rayleigh, Mie and ozone, with multiple scattering. It gives blue skies, bright horizons and red sunsets, and the sun light's colour follows it.
  * An image's sun is found and cut out, and the sun light takes its place.
  * In front of either sky there are volumetric clouds, and their shadows drift over the scene.
  * The sky lights everything: camera view, GI, reflections, fog.
  * Cost: 0.2–1 ms per frame, whatever the resolution.
* **Generated plants:** oaks, birches, conifers, dead trees, bushes, ferns and grass, grown from a seed in about 2 ms.
  * A tree is an **assembly**: a trunk, limbs and a few hundred placed copies of six shared boughs. The forest's 2,500 trees are 29 plants of 3,500 parts.
  * **Wind** turns every limb and bough about its bone, and leans the grass, without rebuilding anything.
  * Far plants are traced as **voxels**; a **season** setting turns the leaves and drops them; leaves let light through.
  * Assemblies, wind and leaf fall are the custom tracer's. Metal's tracer renders the same plants as plain, still meshes; it can trace far ones as the same voxels, which is slower there and off by default.
* **Volumetric fog and light:** height fog with drifting noise, plus soft-edged local fog volumes (ground mist, a stage haze, a glow around a lamp).
  * Every light type scatters in it, with ray-traced shadows, so sunlight falls in shafts through windows and spot beams are visible.
  * It is computed in a camera-aligned voxel grid ("froxels"), 8×8 traced pixels by 64 depth slices.
  * Reflections are fogged too.
  * Cost: 0.2–1 ms at 640×400.
  * It matches a per-pixel ray-marched reference within 1.5% (see below).
* **Custom ray tracing (default):** the shaders traverse this project's own two-level BVH instead of Metal's acceleration structures.
  * Each mesh gets a bottom-level tree (binned SAH, built once on the CPU).
  * Objects that never move get a top-level tree of their own, also built once.
  * Moving objects and light spheres get a top-level tree rebuilt from scratch on the GPU every frame as an LBVH: Morton codes, a bitonic sort, the Karras hierarchy and a bottom-up box pass. This takes 0.08–0.12 ms for 400–2000 objects.
  * Rays walk both levels in a single loop.
  * On an M1 Max, which has no ray-tracing hardware, this is 19–24% faster per frame than Metal's intersector in the stress test, and on par in the Cornell room (see below).
  * Metal's acceleration structures stay one click away in the settings panel ("Ray tracing"), and so does `METALRENDERER_RT=metal`.
* **glTF models:** `.glb` and `.gltf` files load with their node hierarchy and metallic-roughness materials.
  * The **Gallery** scene shows every model in `Assets/` on plinths, two of them on turntables, under 8 moving lights.
  * File > Open… (⌘O) or dropping files on the window adds models to any scene.
  * Textures supported: base colour, metallic-roughness, normal and emissive (normal maps use tangents derived per triangle from the UVs).
  * Scenes load in the background while the old one keeps rendering.
* **Virtual geometry (Nanite-style, default with the custom tracer):** meshes of 65k+ triangles become level-of-detail DAGs of 128-triangle clusters.
  * Everything is this project's own code: clustering, quadric simplification with locked group borders, seam- and border-aware collapses, and the DAG.
  * Each model is built once (about 7 s per 2M triangles) and cached in `Assets/.metalrenderer-cache/`.
  * Every few frames a background thread picks Nanite's cut for each instance: every cluster whose simplification error projects to under 1 traced pixel and whose parent's doesn't.
    * The cut is computed in parallel, tests each group once before its clusters, and skips instances it can prove unchanged. Those are instances that haven't moved, with the camera closer to where it was than any test is to flipping, so a still camera costs nothing.
  * Each instance whose cut changed gets a fresh SAH BLAS over exactly those triangles, read from the memory-mapped cache, so the OS streams pages from disk. The pages are prefetched with `madvise` first, and BLAS buffers are recycled.
  * Big cut changes (the first load, a jump, a new error setting) are published within milliseconds as a *spliced* BLAS: an SAH tree over the clusters with each cluster's own BVH from the cache under it. The SAH tree replaces it in the background.
    * Gallery, M1 Max: spliced rebuilds take 1–9 ms against 20–150 ms for SAH, but trace about 50% slower.
  * Rays see one tight tree per model.
  * The gallery's 17.9M triangles trace as a 0.4M-triangle cut in 40 MB, instead of ~1.5 GB, at about the same speed (see below).
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
* **Global illumination, three methods** (switch with **M** or in the settings panel):
  * **Radiance cascades (default):** probes on a screen grid trace world-space rays over distance intervals that grow 4× per cascade. The cascades are merged top-down, giving each probe its incoming light without noise.
  * **Path traced:** a 1-sample-per-pixel diffuse path is traced for 1 to 8 bounces. Each bounce samples one light directly (next-event estimation), picked in proportion to its unshadowed light there, and picks up sky light. The result is denoised.
  * **ReSTIR GI:** the same paths, but each path's first bounce is kept as a reservoir sample and resampled from frame to frame (optionally also from neighbouring pixels, unbiased). Its paths' last hits add last frame's indirect light (multi-bounce). It is the most accurate method: 42.2 dB in the Cornell room and 36.4 dB in the stress hall, against 36.1 and 25.5 dB for radiance cascades, for 2–3× their cost (see "Indirect light (ReSTIR GI)" below).
  * Radiance cascades get **multi-bounce** light, and light their ray hits from per-light **light-visibility maps**, so they need no shadow rays.
* **Light-visibility maps:** each frame, every light traces a 128×128 map of the distance to the nearest geometry in each direction (smaller beyond 16 lights, so all the maps together always cost about as much as 16). The sun's map is orthographic instead, over the scene's bounding sphere. Secondary hits look up their shadowing there: from every light with up to 8 lights, otherwise from 4 lights picked by their unshadowed light. The path tracer can also use these maps for its bounces ("light bounces from light maps").
* **Upscaling (optional):** the frame is traced at low resolution with sub-pixel jitter, and a temporal upscaler rebuilds a sharper, anti-aliased image at up to 3× the resolution. It's on by default at 3×. Press **U** to cycle through off, 1.5×, 2× and 3×. The settings panel picks the upscaler:
  * **Custom (TAAU)** (default): this project's own pass (`taauKernel`). It is about 0.5 ms cheaper per frame than MetalFX, much sharper and steadier on still images, and as good in motion at 3× (see below).
  * **MetalFX temporal**.
  * **MetalFX spatial**: cheaper still, but it doesn't anti-alias edges.
* **Blue-noise sampling (on by default, B):** random numbers come from a 128×128 void-and-cluster blue-noise tile, shifted every frame by the golden ratio or the R2 sequence. Its stratified shadow samples steady the shadow denoiser's history clamp.
* **Shadow denoiser (direct light):** per light, direct light is an exact unshadowed term times the visibility of one random point on the light. Only that visibility is noisy, so only it is filtered (one light per channel; with more than 4 lights, one light group per channel), and the composite pass multiplies it back onto the exact unshadowed light. Shading is never blurred. The temporal pass clamps the reprojected history to what the current frame's neighbourhood allows, so moving shadows don't lag. Then up to 3 edge-aware 3×3 passes blur no wider than each light's penumbra, estimated from occluder distances, and skip 8×8 tiles that are fully lit or fully shadowed. This follows AMD FidelityFX's shadow denoiser and NVIDIA's SIGMA.
* **SVGF denoiser (indirect light):** temporal accumulation (16 frames) with motion vectors and disocclusion checks, then a 4-pass edge-aware à-trous wavelet filter guided by variance. It filters path-traced indirect light (or cascade light if you enable that). With the shadow denoiser off, it also filters direct light as before. The settings were tuned against converged reference images (see below).
* **Settings panel:** a floating **Render Settings** panel (Tab or ⌘,) has a control for every setting, including the GI method and its parameters and the denoiser parameters. It remembers your settings between launches and copies them as `METALRENDERER_*` variables (see [The settings panel](#the-settings-panel)).
* **Debug window:** a floating **Debug** window (I or ⌘I) shows a frame-time graph, GPU time per pass, the scene's instance, triangle and light counts, virtual geometry's cut and streaming, texture streaming, GPU memory and the custom tracer's traversal counters (see [The debug window](#the-debug-window)).
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

This runs a fixed animation through a list of settings (GI bounces, denoiser, render scale, MetalFX upscaling), times each GPU pass, prints a table, and quits. Set `METALRENDERER_BENCH_DIR=<folder>` to also save one PNG per setting. Benchmarks run without a window: no Dock icon, and the focus stays with whatever app is in front. They render into offscreen textures the size of the window on a Retina screen (1280×800 points at 2×), so the PNGs and timings match a windowed run; `METALRENDERER_WINDOW=1` shows the frames in the window instead. `METALRENDERER_BENCH=shot` renders one still of the default look (paused at t = 5 s; `METALRENDERER_SHOT_FRAMES` sets the frames after warm-up), to check what a change does with any of the `METALRENDERER_*` overrides below. Use `METALRENDERER_BENCH=quality` to render the same frames natively and with MetalFX instead, so you can compare the PNGs. Use `METALRENDERER_BENCH=noise` to render white- and blue-noise sampling next to converged reference images, made by averaging thousands of frames of the paused scene. Use `METALRENDERER_BENCH=denoise` to render a few frames for scoring denoiser changes against those references. Set `METALRENDERER_DENOISE`, for example `passes=3,tpasses=2,sigma=2,history=16,antilag=1,separate=1`, to override the denoiser in every setting without rebuilding (`tpasses` is the pass count with cascade GI).

Each pass runs in its own command buffer so it can be timed, which serializes the whole frame. A pass that runs in more than one buffer per frame (reflections, composite with its reference averaging, MetalFX after TAAU) reports the sum; before October 2026 it reported only its last buffer. Set `METALRENDERER_BENCH_SPLIT=0` to encode frames exactly as the app does (one command buffer, with radiance cascades overlapping the denoiser) and report only whole-frame GPU time. `METALRENDERER_OVERLAP=0` turns that overlap off, for A/B timing. The table's last column, `cpu`, is the CPU's own work per frame (animation, uploads, encoding), without its waits for a frame slot and the drawable; the Debug window shows the same number as "encode".

Use `METALRENDERER_BENCH=shadow` to score direct-light denoising (static, moving and camera-move frames against a converged reference). Use `METALRENDERER_BENCH=upscale` to score the upscalers against supersampled native 1920×1200 references, on the albedo view and on direct light. `METALRENDERER_UPSCALERS=metalfx,custom,spatial` picks the upscalers, and `METALRENDERER_GI=upscaler=metalfx` switches every setting to one (`scale=0.75,factor=2` tests another upscale factor against the same references). Its "pan" frames fly the camera over the frozen scene; `METALRENDERER_PAN=rotate` makes that a pure rotation. `METALRENDERER_DENOISE` also takes `shadows=0` (SVGF for direct light), `spasses`, `shistory`, `sclamp` and `ssigma`. `METALRENDERER_GI` takes `blue` and the custom upscaler's `taau…` keys (see `Benchmark.swift`).

Use `METALRENDERER_BENCH=stress` to time the stress scene against light count (1 to 256), object count (0 to 2000) and GI method, and `METALRENDERER_BENCH=stressq` to score its direct light at 32 and 128 lights, and its final image, against converged references. `METALRENDERER_SCENE=stress,objects=400,lights=32` loads the stress scene in every setting of any mode. `METALRENDERER_LIGHTS=all` traces one shadow ray per light again (the brute-force baseline), `METALRENDERER_GI=lightrays=2` sets the shadow rays per light group, and `METALRENDERER_TLAS=<frames>` sets the rebuild interval of Metal's TLAS (1 = every frame; the custom tracer rebuilds its own every frame). `METALRENDERER_BENCH_ONLY="32 lights|camera"` runs only the settings whose names contain one of these strings.

`METALRENDERER_RT=metal|custom` picks the ray tracer for every setting. Use `METALRENDERER_BENCH=rt` to compare the two:
* It first renders paused frames in every GI mode on both scenes with the `METALRENDERER_RT` tracer. Run it once per tracer and diff the PNGs with `Tools/eval/pngdiff.py`.
* Then it times moving frames at 0–2000 objects, alternating the two tracers.

`METALRENDERER_RT_BUILD=cpu` builds the custom tracer's moving-object tree on the CPU with binned SAH instead of on the GPU (a better tree, for comparison). `METALRENDERER_RT_CHECK=1` checks every mesh's tree against brute-force ray/triangle tests at startup. `METALRENDERER_MATH=relaxed` compiles the shaders with relaxed instead of fast math (infinities and NaNs behave exactly), to rule fast math out when an image looks off; `safe` also keeps the order of every operation. `METALRENDERER_VARIANTS=0` runs every kernel's general pipeline instead of its variant with the configuration's flags compiled in (see "Kernel variants" in the notes below), and `=log` prints each variant as it is made. `METALRENDERER_RT_STATS=1` compiles traversal counters in (the Debug window can also turn them on), and benchmarks print them per setting: nodes, instance and cluster entries, and triangle tests per ray.

Use `METALRENDERER_BENCH=gallery` for the glTF gallery. It renders path-traced references (full BRDF, full-detail meshes, 4 bounces; skip them with `METALRENDERER_GI_REFS=0`), then the overview and a close-up with full-detail meshes and with virtual geometry at 0.5, 1 and 2 px, alternating so heat affects them alike, and the camera fly-through. Score it with `Tools/eval/gallery.py`.

These variables apply to the gallery and to models in general:
* `METALRENDERER_SCENE=gallery` starts the app in the gallery; `model=<path>` adds a model, as File > Open does.
* `METALRENDERER_GALLERY="owl|demon"` loads only the matching files; `METALRENDERER_ASSETS=<folder>` uses another folder.
* Virtual geometry:
  * `METALRENDERER_VG=0` turns it off; `METALRENDERER_VG_TAU=<px>` sets the allowed error.
  * `METALRENDERER_VG_MODE=clusters` uses the GPU-driven cluster variant (see below), with `METALRENDERER_VG_POOL=<MB>` for its page pool.
  * `METALRENDERER_VG_SYNC=0|1` forces background or synchronous cut updates; benchmarks run them synchronously.
  * `METALRENDERER_VG_BLAS=hybrid|spliced|sah` picks the per-instance BLAS builder. `hybrid` is the default: spliced for big cut changes, then SAH. Benchmarks (synchronous) build SAH.
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
* `METALRENDERER_BENCH=crowd` times it against the number of poses, of characters and the level of detail, then renders a still and a camera move. With `METALRENDERER_CROWD_CHECK=1` every captured frame compares the vertices the GPU skinned with the CPU's, and (custom tracer) checks the refitted trees box by box.
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
* `METALRENDERER_SCENE=forest,cards=1` shows the trees' leaves as cards; `baked=1` bakes the plants into plain meshes on the custom tracer too.
* `METALRENDERER_FOLIAGE="wind=0.4,dir=25,gusts=0.7,season=0.3,translucency=1,lod=2"` sets the Foliage section of the panel.
* `METALRENDERER_BENCH=forest` renders the forest paused (from the clearing, from above, close to a trunk, with 10,000 trees), then moving, natively and at 3×.
* `METALRENDERER_BENCH=forestcheck` renders the checks described under "Generated plants".
* `METALRENDERER_FOLIAGE_TEST=<seed>` builds every plant, times and checks them, and exits; with `METALRENDERER_FOLIAGE_TEXTURES=<folder>` it also writes the generated textures there as PNGs.
* `METALRENDERER_SCENE=world` starts in the Open world; `seed`, `trees` and `undergrowth` change it as they change the Forest, and `lit` the share of lit windows at night. Its day starts in mid-morning: `METALRENDERER_VIEW=tod=0.6` starts it at midnight (`tod=0.41` as the sun sets). `METALRENDERER_BENCH=worldnight` renders the night from a street, a street corner, above the first city and 2 km from it, then drives 600 m down a street; `METALRENDERER_BENCH=worlddusk` renders the first city from above and from a street at eleven times from afternoon to the next morning, then lets 20 s of dusk go by in each view; `METALRENDERER_BENCH=worldground` renders the first city's ground: a junction of two streets from above and from its corner, a courtyard, the last street and the fields beyond it, the roads from over the city and from 2 km, and the junction at night; `METALRENDERER_BENCH=worldroads` renders the road from the first city to the next one: from the junction it leaves by, from the fields, before its deepest cutting and its highest bank, in the woods, from above, all of it from over the city, from short of the other city and at night, then flies 600 m along it; with `METALRENDERER_SHOT_SWAP=<k>` a setting ends, and its picture is taken, `k` frames after its scene is first made again (around another tile, or with the cities' lights). `METALRENDERER_BENCH=world` renders it from where it starts, from a street, in the woods and from above, then flies 600 m across its tiles, and renders the start with the scene's origin elsewhere and a place 50 km out. `METALRENDERER_WORLD_TEST=<seed>` makes the tiles around the first city, says what they hold and how long they took, and exits. `METALRENDERER_WORLD_GROUPS=0` makes every tile's trees again with every scene, as the scene's own instances (for comparing with the groups they are in otherwise), and `METALRENDERER_BLOCK_PART=<n>` sets how many instances of a group the custom tracer's top-level tree takes as one leaf (16).
* `METALRENDERER_FLIGHT="x,y,z,frames"` flies the camera in every benchmark setting: metres a second, and with `frames` there and back again, turning every so many frames.
* `METALRENDERER_CACHE=0` makes everything a generated scene derives again (its textures, its meshes' trees, the plants' voxels) instead of taking it from `~/Library/Caches/MetalRenderer/generated`; `=1` caches the trees and voxels in an optimised build too. `METALRENDERER_CACHE_MB=4096` caps that folder.

The models in `Assets/` (596 MB) are stored with [Git LFS](https://git-lfs.com): install it before cloning (`brew install git-lfs && git lfs install`), or run `git lfs pull` afterwards. `.gitattributes` sends 3D models (`.glb`, `.fbx`, `.obj`, `.usd(z)`, `.blend`), HDR skies (`.hdr`, `.exr`) and the buffers and textures under `Assets/` to LFS. Put any glTF files there. The caches in `Assets/.metalrenderer-cache/` (4.4 GB for the 11 sample models: 1.9 GB of geometry DAGs, 2.5 GB of texture mip chains) can be deleted at any time; they're rebuilt on the next load.

Use `METALRENDERER_BENCH=gi` to compare the GI methods. It first renders 8-bounce, unclamped path-traced references by averaging thousands of frames of the paused scene; skip them with `METALRENDERER_GI_REFS=0` once you have them. Then, for each method, it renders a static frame, the next one (for flicker), an indirect-only frame, a moving frame, a frame at the end of a scripted camera move, and a frame with MetalFX on. `METALRENDERER_GI_MODES` picks the methods, for example `pt,pt-lightmaps,cascades,cascades-hq,restirgi,restirgi-q`. `METALRENDERER_GI` overrides GI settings everywhere, for example `mode=pt,bounces=4`, `mode=cascades,spacing=4,b1=0.25` or `mode=restir`. `METALRENDERER_TG`, for example `trace=16x8`, overrides a kernel's threadgroup size.

`Tools/eval/` scores the saved PNGs against reference images committed in `Tools/eval/refs/` (PSNR and flicker; see its README).

Use `METALRENDERER_BENCH=hwrt` to time hardware ray tracing and MetalFX's denoising scaler against what they replace: each ray tracer with each output (`custom`: SVGF and the custom upscaler, `metalfx`: SVGF and MetalFX's temporal scaler, `denoiser`: MetalFX's denoising scaler in place of all of it), path traced and with radiance cascades, in the Cornell room and the stress hall. `METALRENDERER_BENCH=hwrtq` renders the same outputs for `Tools/eval/hwrt.py` to score against supersampled 1920×1200 references, and `METALRENDERER_BENCH=api` runs the same frames through Metal 3 and Metal 4 (`METALRENDERER_API=metal3|metal4` picks the API for every setting, as `METALRENDERER_RT` picks the tracer). `METALRENDERER_UPSCALERS=custom,denoiser` picks the outputs. Settings that need something the GPU or the system lacks are skipped, and the run says which (`skipped: … (needs the MetalFX denoiser)`); `METALRENDERER_CAPS=rt,metalfx` keeps only the capabilities it names (`rt`, `hwrt`, `metalfx`, `denoiser`, `metal4`, or `none`), to try that on a GPU that has them all. The results are under "Hardware ray tracing, MetalFX's denoiser and Metal 4".

Benchmarks render into offscreen textures, so the window server never paces them. With `METALRENDERER_WINDOW=1` it can: on an M4 Max under macOS 26.5 it handed drawables out at the display's rate (8.0–8.3 ms a frame) even though display sync is off. The pass that writes the drawable then waits for it, and its time, or the whole frame's with `METALRENDERER_BENCH_SPLIT=0`, reads as the display's period (8.0 ms for a frame that takes 0.8 ms); the GPU also idles between frames and clocks down, which inflates every other pass. If `span` sits near your display's period whatever the setting, this is happening. The M4 Max numbers in this file were taken into a texture.

The benchmark renders frames back to back without vsync, so the GPU's clock stays steady. Long runs can still throttle as the GPU heats up, so compare timings from short runs. The lists of settings are in `Benchmark+Modes.swift`, one function per mode.

## Controls

| Key | Action |
|---|---|
| Drag mouse | Look around |
| W A S D, Q E | Move, down/up (hold Shift to move 3.2× faster; the speed is in the panel) |
| Space | Pause animation |
| G | Toggle global illumination |
| M | GI method: path traced, radiance cascades, ReSTIR GI |
| N | Toggle denoiser (shows the raw 1-spp signal) |
| [ ] | Fewer / more GI bounces (path traced, ReSTIR GI) |
| - = | Lower / raise render resolution |
| U | MetalFX upscaling: off, 1.5×, 2×, 3× (output is capped at the window's pixel size) |
| B | Toggle blue-noise sampling (on by default; the tile is generated once, in the background of the first launch, and kept in `~/Library/Caches/MetalRenderer`) |
| 1–8 | View: final, raw direct, raw indirect, normals, albedo, history length, indirect only, GI debug (cascades: probe grid over interpolation confidence) |
| 9, 0 | Cycle the geometry debug views (see below); back to the final image |
| L | Freeze LOD: virtual geometry keeps choosing detail for where the camera is now |
| R | Hot-reload the shaders. It compiles in the background: the view keeps drawing with the old shaders until the new ones are ready, and keeps them if the compile fails |
| ⌘O, drop files | Add glTF models (`.glb` / `.gltf`) in front of the camera, or an HDR sky (`.hdr` / `.exr`) |
| Tab, ⌘, | Show or hide the Render Settings panel |
| I, ⌘I | Show or hide the Debug window |

The window title and the Debug window show the resolution, frame rate and GPU time. The panels never take keyboard focus, so the keys above keep working while it's open, and changes you make with the keys show up in it.

### The settings panel

* **Sections** fold with their triangles; the panel scrolls and can be resized, and keeps the size you drag it to. Rows that don't apply to the current mode are hidden (the stress scene's object count, each GI method's parameters, ReSTIR's, fog's while it's off).
* **Show advanced** (at the bottom) adds every remaining setting: ReSTIR DI's chains, confidence cap, neighbours, radius, the light grid's shape, split visibility and its own denoiser; ReSTIR GI's light maps, multi-bounce sources, caps, radius, minimum distance and its own denoiser; the shadow denoiser's history, clamp and edge tolerance; the custom upscaler's history, colour clip, sharpness and motion cuts; fog's base height, noise tile, wind and albedo; the clouds' thickness, size, erosion, wind direction and shadow strength; an HDR sky's exposure; and a Memory section (geometry pool, texture budget).
* **Camera and time:** exposure (EV) and the tone curve, the field of view, the move speed, the animation's speed, and, in the scenes with a day cycle, the time of day (an offset into the cycle that moves only the sun and the sky; it works while paused). In the Open world that is the whole day: 41% is sunset, 60% midnight. At their defaults (0 EV, ACES, 60°, 1×) images are bit-identical to before.
* **What the GPU can't run** stays listed and greyed out: Metal ray tracing, the MetalFX denoiser (Rendering > Upscaler, macOS 26) and Metal 4 (Scene > Graphics API, macOS 26). The launch log's first line says what was found (`Metal ray tracing: hardware, MetalFX upscaling: yes, MetalFX denoiser: yes, Metal 4: yes`), and "Ray tracing" names Metal's tracer "Metal (hardware)" on GPUs with ray-tracing hardware (M3, A17 Pro and later) and "Metal (software)" on the others. A saved setting or an environment variable that asks for something missing falls back to the default with a line in the log.
* **Denoiser:** a caption says what the generic rows (passes, σ, history, anti-lag) filter in the current mode. ReSTIR DI and ReSTIR GI filter their own signal with their own settings, under Show advanced in their sections.
* **Remembered:** settings are saved (UserDefaults) half a second after each change and restored at the next launch, except the pause, the view, Freeze LOD and added models. `METALRENDERER_SETTINGS=default` starts from the defaults instead. Benchmarks never read or write them.
* **Copy as Env** puts the `METALRENDERER_*` variables that reproduce the current settings on the clipboard, listing only what differs from the defaults (fog and sky from the scene's preset). They work in a normal launch, where they override the saved settings, and in benchmarks, where they apply to every setting. A key the app doesn't know, or a value it can't read, is reported on the console and skipped. `METALRENDERER_DUMP_SETTINGS=1` prints the settings as JSON at startup, to compare two launches. The camera pose and where added models were placed aren't included.

The environment variables, in a normal launch and in benchmarks: `METALRENDERER_SCENE`, `METALRENDERER_GI` (now also `on=0` for GI off), `METALRENDERER_DENOISE`, `METALRENDERER_RESTIR`, `METALRENDERER_RESTIR_GI`, `METALRENDERER_FOG_SET` (now also `albedo=r:g:b` and `wind=x:y:z`), `METALRENDERER_SKY_SET`, and `METALRENDERER_VIEW="exposure=1,tonemap=agx,fov=70,speed=5,timescale=0.5,tod=0.25"` (plus `view=<index>` and `paused=1` outside benchmarks). The plain ones (`METALRENDERER_DIRECT`, `_RT`, `_VG`, `_VG_TAU`, `_VG_POOL`, `_SPECULAR`, `_TEXTURE_BUDGET`, `_FOG`, `_SKY`) set defaults, as before.

### The debug window

I or ⌘I shows it (it reopens at launch if it was open at quit). Everything refreshes twice a second; the graph, every frame.

* **Frame:** resolution, frame rate and GPU time, and a graph of the last 300 frames' GPU time (blue) and CPU frame interval (orange: the time between frame starts, so it includes waiting for the display), with their current, average and maximum and guides at 60 and 30 fps.
* **GPU pass timings** lists each pass's GPU time, averaged over half a second. Each pass then gets its own compute encoder, timestamped at its start and end (Apple GPUs sample counters only at encoder boundaries), and the encoders run one after another (a fence between each pair: without it, independent passes such as ReSTIR and fog overlapped and the sum came to 1.6× the frame time). The radiance cascades also no longer overlap the denoiser, so the frame is a little slower while it's on. MetalFX, its copy into the drawable and texture streaming can't be timestamped; they show as "other", the frame's GPU time minus the timed passes. It stops while the window is closed.
* **Scene:** instances (how many are virtual geometry), triangles over the non-virtual instances, lights by kind, whether the light table is on (more than 256 lights), the direct-light method Auto picked, the GI method and the ray tracer.
* **Virtual geometry** (scenes with glTF models, custom tracer). With per-instance BLAS (the default): the meshes, the triangles traced this frame against the finest level's count (the cut's share), the clusters in the cut, the BLAS memory, the rebuilds (total and per second: each happens when an instance's cut changes, on a background thread) the last one's time, the last background SAH refinement, the last cut's time and how many instances it skipped as unchanged, the pixel error, and whether the LOD is frozen. With `METALRENDERER_VG_MODE=clusters`: clusters drawn against the 65,536 capacity (red when reached), groups resident in the streaming pool, the pool's use, requests waiting and groups loaded this frame. A popup switches between the final image and the geometry debug views, next to Freeze LOD.
* **Texture streaming:** resident megabytes against the budget, mip levels mapped, and megabytes uploaded since launch.
* **Memory:** what the GPU has allocated, and the working-set limit.
* **Ray traversal** (custom tracer): turning the counters on recompiles the shaders with `RT_STATS` (a few seconds in the background, as with R); tracing is slower while they're on. Then: rays per frame, and per ray the top-level and bottom-level nodes visited, instance and cluster entries, triangle tests, and stack overflows (pushes the traversal's 64-entry stack had no room for: each is a subtree a ray skipped, so anything but "none" means `RT_STACK` is too small for the scene's trees). They match what a benchmark with `METALRENDERER_RT_STATS=1` prints for the same view. The window reads the GPU's counters every frame and shows the increase, since a reset from the CPU doesn't stick while frames are in flight.

### Scene settings

| Setting | Default | Effect |
|---|---|---|
| Scene | Cornell room | Cornell room (5 objects, 2 moving, 3 lights), the stress test, the Gallery of glTF models in `Assets/`, or one of the light demos and the Misty hall (see below). Switching rebuilds the geometry and acceleration structures in the background, and picks that scene's fog and sky defaults (and resets the GI method to radiance cascades). Reset to Defaults also uses the current scene's. The gallery's first load builds its geometry and texture caches (about a minute for 11 models); later loads take seconds. |
| Objects | 400 | Stress test: objects in the hall, about 85% of them moving. Applied when you release the slider. |
| Lights | 32 | Stress test: moving sphere lights, 1 to 16384. Their total power stays the same, so the brightness barely changes; above 256 the bulbs also shrink. Night market: festoon bulbs, 4096 by default. |
| Characters | 2048 | Crowd: how many characters stand, walk and run in the square, 1 to 131072. Applied when you release the slider. |
| Poses | 64 | Crowd: how many poses the GPU animates each frame; every character shows one of them. More poses, fewer characters in step with each other. |
| Detail level | 3 | Crowd: the mesh the poses are skinned at. 0 is the full mesh (about 50k triangles), each level has half the triangles of the one before (level 3: about 6.5k). |
| City seed | 1 | City: which city is built, 0 to 999 (the same setting as the plants' seed, `seed`). Applied when you release the slider, as the others below. |
| City blocks | 4 × 4 | City: blocks along each side of the street grid, 1 to 10. |
| Building style | Mixed districts | City: every style by district, or one of them everywhere (old town, residential blocks, warehouses, office towers, modern mid-rise). |
| Lit windows | 35% | City at night, Open world: the share of windows with a light behind them, on at night. |
| Rooms behind windows | 15% | City: the share of windows with a room behind the glass instead of a blind, 0 to 50%. |
| Generated textures | On | City: brick, plaster, concrete, tile and paving textures. Off: flat colours. |
| Ray tracing | Custom BVH | Custom BVH or Metal's acceleration structures and intersector. Switching recompiles the shaders and rebuilds the scene's trees in the background, while the view keeps drawing with the old tracer (2 to 4 seconds the first time, then milliseconds). The images match to 58–72 dB PSNR, and every quality score in the benchmarks is within ±0.2 dB. |
| Virtual geometry | On | Custom ray tracer only: big glTF meshes as streamed level-of-detail cuts. Off: full-detail meshes. |
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

### Light types

Each light demo is procedural, so it loads at once. Each demo scene shows one light type, and every light in it moves, sweeps or flickers.

| Type | Shape and units | Diffuse | Specular | Demo scene |
|---|---|---|---|---|
| Sphere | Sphere of radius r; intensity I (power 4πI) | Exact for a sphere above the horizon | Representative point (Karis 2013) | Cornell, stress, gallery |
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

**Custom tracer:**

| Megaplants feature | Here |
|---|---|
| Nanite Assemblies | A third instancing level. A plant is a tree over its parts, stored once with the static top-level nodes and shared by all its instances; a part is a placed mesh. The forest stores 283k triangles instead of 2.25M, and its BVH builds in 65 ms instead of 144. |
| Skinning and wind | Every part has two rigid bones (its limb, and itself on that limb), and the plant leans about its foot. The turns are functions of the time: the traversal turns the ray back as it enters a plant and a part, and the shading turns the hit point forward, at this frame's time and the last one's, so moving leaves have motion vectors. Only the part boxes' padding is refitted, when the wind's strength changes. Grass and ferns have no bones: a patch is sheared downwind by its height, which the traversal undoes the same way. |
| Nanite Voxels | Each plant has a 32-voxel grid with two coarser levels (1.7 MB for the forest). A voxel holds its optical depth, its share of leaf and its mean normal. A plant whose voxels are about 2 traced pixels (the `lod` setting) is marched instead of traced, and a ray stops in a voxel with the probability that it would have hit something there. Every ray sees a plant the same way, since the level goes by the camera. |
| Seasons | The Season setting recolours the leaf materials, each shade of each species in its own time, and from late autumn drops leaves: a plant traces only the first part of each bough's (shuffled) leaf triangles. Conifers keep theirs. |
| Two-sided foliage | A share of the leaves (35% for broad leaves) shows the light of its far side: for those, lighting, shadow rays and bounces use the flipped normal. Which leaves is fixed per leaf. It is an approximation: a leaf is lit from one side or the other, never both. The path-traced reference does the same, so the GI methods agree with it (below) without that proving it right. |

**Textures** are generated too (`FoliageTextures.swift`): furrowed bark, birch bark, a veined leaf, a needle, a grass blade, and a colour map of the forest's ground (moss, the clearing, the trail, rock on slopes). A plant's texture is detail on its material's colour and has a fixed mean, so a plant's far voxels, which use the colour alone, match its triangles (within 1% from above).

**Leaves as cards** (`cards=1`, off by default): each stretch of twig becomes two crossed rectangles showing a picture of the twig with its leaves, cut out by an alpha mask. The mask's texel coordinates ride in the spare floats of the card's triangles, and the traversal tests them (`rtCutout`). Custom tracer only; with Metal's, the leaves stay meshes.

| Foliage setting | Default | Effect |
|---|---|---|
| Wind | 0.4 where there are plants | 0 = still, 1 = strong. At 0 the wind code is compiled out of the kernels. |
| Wind direction, Gusts | 25°, 0.7 | Where it blows to; how much it comes in waves, which travel downwind. |
| Season | 0.3 | 0 = spring, 0.3 = summer, 0.5–0.8 the leaves turn and fall, 1 = winter. |
| Leaf translucency | 1 | Scales every species' share of backlit leaves; 0 = opaque leaves. |
| Distance LOD (voxels) | 2 px | The voxel size, in traced pixels, at which a plant is marched instead of traced. 0 = never. At 4, near trees turn visibly grainy. |
| Far plants as voxels | Off | Metal's tracer: far plants as their voxels instead of their triangles. Slower wherever it was measured (below). `voxels=1`. |
| Trees, Undergrowth, Plant seed | 2500, 100%, 1 | The Forest. Applied when the slider is released. |
| Leaves as cards, Plants as plain meshes | Off | See above. |

**Voxels on Metal's tracer** (`VoxelLOD.swift`, `VoxelGrids.swift`). The baked plants have the assemblies' grids (the same cells: one builder, `FoliageVoxels.Plant`, for both tracers). Each grid level is a bounding-box structure of one box, whose primitive data names the grid and the level. A far plant's wood instance points at its level's box and its leaf instance is masked out, and the ray queries become intersection queries: the traversal hands each box it meets to the shader, which marches it with the custom tracer's `rtVoxels` and keeps the nearest hit itself, while triangles stay the traversal's own. The levels follow the custom tracer's rule, Freeze LOD and the `lod` bias included.
* A still scene's instance structure is built once, for tracing. When the camera has moved a metre, the levels are picked again on the CPU (the open world's 700,000 plant instances in 14 ms) and another structure is built in the background (36 ms on an M1 Max) and swapped in at a frame's start: the levels trail the camera by a few frames, and the frames trace as fast as before. Benchmarks rebuild at the frame's start and wait, so their pictures don't depend on timing.
* Measured on an M1 Max (software ray tracing), the forest from above, 960×600: the voxels have the triangles' mean brightness (73.8, 77.2, 67.6 against 73.8, 76.7, 67.9) and the LOD view matches the custom tracer's plant for plant. But the intersection queries cost every ray about 30% (`forest`, every view, no plant as voxels), more than far plants as voxels save (9% of the frame from the air, nothing from the ground).
* Measured on an M4 Max (hardware ray tracing, Metal 4; `METALRENDERER_BENCH=forest` and three views of `worldroads`, medians of 3 alternating rounds): the intersection queries alone cost a frame 3–15%. With far plants as voxels the forest takes 4.7–9.6 ms a frame against 2.6–4.9 ms with triangles, and the open world's views 8.7–11.5 ms against 2.7–3.8 ms. The cost is the hand-over: every box a ray meets stops the hardware's traversal and gives the ray back to the shader. Handing the road views' boxes over without marching any takes 8.4–9.4 ms a frame; marching them all adds 1–2 ms. The hardware gets through a far tree's triangles faster than it gets to the shader and back.
* So far plants are triangles on Metal's tracer by default, on every Mac. With voxels on by default wherever there is ray-tracing hardware, the open world took 14–72 ms a frame here on Metal's tracer (`METALRENDERER_BENCH=world`) instead of 2.9–5.1 ms.

**Cost** on an M4 Max, the forest moving, 640×400 upscaled to 1920×1200 (`METALRENDERER_BENCH=forest`, "forest moving 3x"), whole frame and the trace pass:

| | Frame | Trace |
|---|---|---|
| Custom tracer, wind 0.4 (the default) | 12.8 ms | 6.6 ms |
| Wind off | 11.1 ms | 5.4 ms |
| Autumn (season 0.8) | 14.4 ms | 7.5 ms |
| Voxels off (`lod=0`) | 13.1 ms | 6.7 ms |
| Leaves as cards | 14.6 ms | 7.6 ms |
| Plants as plain meshes (`baked=1`), still | 10.0 ms | 4.5 ms |
| Metal's tracer (hardware ray tracing), plain meshes, still | 3.1 ms | 0.7 ms |

* On this Mac, Metal's hardware ray tracing is three times faster on the baked forest than the custom tracer, and it gets none of the wind, the voxels or the leaf fall. The forest wasn't measured on a Mac without ray-tracing hardware.
* The valley costs 2.5 ms a frame with its 16 generated trees, up from 1.9 ms with the box-and-sphere placeholders (2.4 ms with the wind off).

**Checks** (`METALRENDERER_BENCH=forestcheck`):
* The forest as assemblies and as baked meshes, with opaque leaves, from the clearing and from above: the same mean brightness (79.4 against 79.3, 72.8 against 72.8 of 255), and single pixels differing on thin geometry (1–3% of them by more than 8 levels).
* Leaves against the sun, each GI method against a 512-frame path-traced reference: means within 1% (71.3 for the reference; 70.9 path traced, 71.2 cascades, 70.6 ReSTIR GI).
* The LOD level view from above: triangles blue, the three voxel levels green, orange and red.
* Scenes without plants render bit-identical to before the plants were added (Cornell, stress, market, gallery).

**Loading** (from the launch to the scene ready to draw; `swift build` is the unoptimised build Xcode's Run uses):

| | Unoptimised, before | Unoptimised | Optimised |
|---|---|---|---|
| Forest, custom tracer | 9.9 s | 0.9 s | 0.17 s |
| Forest, Metal's tracer | 4.7 s | 1.25 s | 0.2 s |

* An optimised build never needed help: the whole forest is made in 0.1 s. An unoptimised one runs the same loops 30 to 100 times slower, and three things took nearly all of its time.
* **The meshes' trees and the plants' voxels are cached** (`SectionFile.swift`, `GeneratedCache`): 6.5 s to build, 0.35 s to read. A file is named by a hash of the geometry it was built from (SHA-256, which the hardware does: tens of megabytes in milliseconds in any build), so changed geometry is another file and none is ever stale. Only unoptimised builds do this (see below).
* **A generated texture is named by what it is drawn from** (its generator's version and the seed), not by its pixels, and is drawn only when the texture cache doesn't have its mip chain: the forest's ground map took 1.7 s. `FoliageTextures.version` is the name's version; a test holds each texture's hash and fails when a pattern changes without it.
* **What takes a loop over a plant's vertices is done for all plants at once**, on every core (`Scene.Flora`): the parts' boxes of an assembly (1.1 s) and the baking for Metal's tracer (2.6 s).
* The cache's files are arrays of the structures the renderer uses, each at a page boundary behind a table of sections: nothing is parsed, and a file of another format, for another key or cut short is a miss. Reading one copies its arrays; it saves no memory.

**What didn't help:**
* **Caching the trees in an optimised build.** It builds a city's trees (5.3 million triangles) in 0.13 s, and takes 0.15 s to hash the meshes and copy the trees out of their 420 MB file. The forest gains 55 ms, the city nothing: not worth the disk.
* **A file of the plant library** (meshes, parts, bones). Planned, and not needed: the library takes 17 ms unoptimised; what was slow was done per plant on one core.
* **Leaf cards.** They store fewer triangles (the forest's 24 boughs lose 9,900 of theirs) and are 13% slower (14.6 against 12.9 ms). A ray visits as many nodes and tests more triangles (13 against 9 per ray), because a card's box covers the whole twig, and each candidate hit reads the mask. One card per twig instead of two crossed was no faster. They are kept as an option.
* **A 64-voxel grid.** Marching 64 steps costs more than tracing the plant's triangles, so a finer level would only ever be slower. 32 it is.
* **Committing a voxel hit to Metal's ray query** (`commit_bounding_box_intersection`), so that the traversal skips what is behind it. The commit costs far more than the boxes it saves: on an M4 Max the open world's road views took 25–30 ms a frame with it and 9–12 ms without, the forest 5.6–13.8 ms against 4.7–9.6 ms. The shader keeps the nearest voxel hit and compares it with the query's triangle at the end. The forest's pictures are the same bit for bit.
* **Padding the parts' boxes for the strongest wind.** It cost 0.3 ms with no wind at all. The boxes are padded by the current strength, and the assemblies' nodes refitted when it changes.
* **Keeping the leaf-fall limit in a register across the traversal loop.** 0.7 ms a frame in the wind; it is computed where a leaf is tested.

**Limitations:**
* Wind and leaf fall need the custom tracer. With Metal's the plants stand still and keep their leaves; their colours still follow the season. Its voxels are off by default (see above), and need a still scene.
* A plant traced as voxels only leans with the wind; its boughs don't move. Far trunks are as grainy as far crowns.
* Dead trees only lean. A patch of grass leans as one.
* The ground's colour map has a texel every 31 cm.

### Animated characters

The **Crowd** scene fills a square with the characters in `Assets/Characters`: every `.fbx` file there is a character, and every `.fbx` in `Assets/Characters/Animations` is a clip all of them can play. The repository's are Mixamo's X Bot and Y Bot with two idles, a walk and a run. Rows of characters walk and run along lanes at their clip's own speed, and others stand around.

* **Poses are animated, not characters.** Everything here is ray traced, so a deformed mesh is not something a vertex shader does to an instance: it needs vertices of its own and an acceleration structure around them. The crowd keeps a pool of *pose slots* (`Crowd.swift`). A slot is one character playing one clip, or a cross-fade of two, from some point of its loop. Each frame the GPU animates every slot once, and every character in the square is an ordinary instance of one slot's mesh. A frame's cost follows the number of slots, not of characters: 131072 characters on 64 slots cost what 64 poses cost, plus a larger top-level tree. Characters on the same slot move in step, which a few dozen slots per clip hide well; a character that must move on its own takes a slot to itself.
* **A frame's work, all in compute** (`Shaders/Crowd.metal`, `CrowdSkinner.swift`):
  * `crowdPoseKernel`, one thread per joint and slot: the joint's skinning matrix. The thread walks up from its joint to the root (a skeleton is about a dozen joints deep), blending each rotation between two keys of the clip and, in a cross-fade, between the two clips.
  * `crowdSkinKernel`, one thread per vertex and slot: linear blend skinning of up to four joints, into the slot's range of the scene's position and normal buffers. Hits then read a pose's vertices like any mesh's (`MeshData.vertexOffset`).
  * The slots' bottom-level structures are refitted: a pose keeps its triangles, so its tree keeps its shape and only the boxes move. The custom tracer does it in `crowdRefitKernel`, one thread per node, bottom-up through the same arrival counters as the top-level build. Metal's tracer refits its per-slot structures; only one is built per character, and every other pose takes that tree, refitted into a structure of its own.
  * Then the top-level tree, as for any moving instance.
* **Motion vectors.** The skinning keeps each slot's previous positions, and a hit on a deforming mesh interpolates them for the point's previous position (`MeshData.prevOffset`). The denoisers, the upscalers and the reuse passes then reproject limbs the way they reproject moving objects. Without it they throw a moving limb's history away, and limbs come out at traced resolution. Both offsets are compiled in only for a scene that has a crowd (`DEFORMING_MESHES`, with the scene's light types): read at every hit of every scene, they cost the trace 7% in the stress hall; now the other scenes trace the code they always did and render the same images, bit for bit.
* **Import** (`FBXReader.swift`, `SkinnedCharacter.swift`): a reader of binary FBX written for this, with no dependencies.
  * The file is memory-mapped and never copied. A node is a 24-byte record of offsets, names are compared as bytes, and what isn't wanted is stepped over by its end offset: a clip file carries a whole copy of its character's mesh that is never touched.
  * Arrays are inflated once, when asked for, straight into the Swift array they become, on all cores. The six files are read at the same time.
  * The skeleton is matched by joint name (the files list the joints in different orders). Clips are retargeted to each character by its joints' rotations away from the bind pose, so X Bot, whose joint axes and bone lengths differ from Y Bot's, plays Y Bot's clips. A clip's travel is taken out and kept as its speed.
  * Coarser levels of the mesh come from `MeshSimplifier`, whose collapses keep a subset of the vertices, so skin weights carry over.
  * On this M1 Max the six files (12.6 MB) are read in 26 ms and retargeted in 2 ms; the levels of detail take 320 ms. All of it is then kept in one cache file, which loads in 3 ms.
* **What it costs** (`METALRENDERER_BENCH=crowd`: M1 Max, 640×400 upscaled 3×, cascades GI, 2048 characters, 64 poses and detail level 3 unless the row says otherwise, the animation running; ms):

  | Custom tracer | skin | blas | tlas | trace | frame (Metal 3) | frame (Metal 4) |
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
  * **Metal's tracer** pays about 0.09 ms per refitted structure on this GPU, whatever its size: 6.3 ms for 64 poses and 23 ms for 256, against 1.2 and 4.6 ms above. Use fewer poses with it.
* **Checked** by `METALRENDERER_CROWD_CHECK=1` in every setting of the mode, on the custom tracer under both APIs and on Metal's under Metal 3: the GPU's vertices are within 3 µm of the CPU's, and no refitted triangle, box or bound is off. Metal 3 and Metal 4 render the same images.
* **The same picture every run.** A shadow ray stops at the first occluder its tree has, and the shadow filter takes that one's distance for the penumbra (`isVisibleBlocker`). Metal builds a pose's tree a little differently from run to run (these meshes, not the other scenes'; more often the more of them it builds, or with the GPU busy). With a tree built per pose the crowd on Metal's tracer came out as one of two pictures at 64 poses (31 pixels in penumbrae, up to 4 levels apart) and as a different one almost every run at 512. Now a character's first pose is built and the others are refits of it, so every pose has its triangles in the same order and only 2 builds are left to vary: the picture was the same in every run tried (16 each at 64 and at 512 poses, on an idle GPU and with three renderers at once, Metal 3 and Metal 4), frame times are within noise of before, and 512 poses load in 0.13 s instead of 0.18 s.
  * Didn't help: building the poses one command buffer at a time (one picture at 64 poses on an idle GPU; not at 512, nor with the GPU busy), an encoder or an unwaited command buffer per build, compacting them, a jitter of the vertices they are built from.
  * Shadow rays that take the closest hit also give one picture, whatever the trees: 0.05 to 0.13 ms a frame on an M4 Max.
* **Limits:**
  * Metal's tracer under Metal 4 needs a GPU with Metal 4 ray tracing (M3 and later): that combination's refit is written the same way, through the Metal 3 queue, but has not been run.
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
* **What it costs** (`METALRENDERER_BENCH=city`: M1 Max, 640×400 upscaled 3×, cascades GI, the custom tracer; ms):

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
  * Metal's tracer runs it too (10 × 10: 1,737 structures, 485 MB after compaction, 6.6 ms a frame), and Metal 4 draws the same images as Metal 3 (but see the limits).
* **Checked** by `CityTests`, `BuildingTests` and `ProceduralTextureTests`: the plan's lots stand inside their blocks and apart; every style's meshes are valid over many seeds and lots (finite, unit normals, no triangle without area or, where textured, without UV area, inside the lot, under the limit); outlines close around their plans; a seed always builds the same city; the textures tile.
* **Limits:** every building is unique, so memory and load time grow with the city; the street grid is a grid; rooms are boxes; there is no night in the day cycle (the sun stays 12 degrees or more above the horizon, and the night scene is its own).

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
  * **Checked** (`METALRENDERER_BENCH=worldroads`): its ten pictures are bit-identical with a cold cache and a warm one, and on Metal 3 and Metal 4 (custom tracer); without the cache the nine stills are, and the flight differs by an RMS of 0.2 levels (its scenes come a few frames later). The two tracers' means agree within 2%. A tile a road runs straight across has 256 more triangles at levels 0 and 1 and 144 more at level 2; the 289 tiles around the first city are made in the time they were, and the views of `world` and `worldground` cost what they did. Every other scene's pictures are the bytes they were.
* **Checked** (`METALRENDERER_BENCH=worldground`): its eight pictures are bit-identical with a cold cache, a warm one and none, and on Metal 3 and Metal 4 (custom tracer); the two tracers' means agree within 1.5% (within 0.1% in the views of the streets; the ones with woods in them differ as the tracers' trees do). The roads, the paint and the kerbs are 0.4% more triangles in the nine tiles around the camera; the tiles are made in the time they were, and the day's and the night's views cost what they did.
* **Woods:** one candidate tree to each cell of a 4 m grid over the whole world, from random numbers of that cell's own, so asking for another piece of the world moves no tree. Woods and open country alternate over half a kilometre; conifers stand higher and on slopes, oaks low, birches at the woods' edge. Bushes and ferns grow in patches under the trees and grass in the open, up to a city's last street; none on a road, and none in a sown field. No tree stands in a city's fields, or beside a road between cities.

**Tiles** (`WorldTile.swift`) are 256 m squares at three levels of detail: the camera's tile and its eight neighbours whole (ground cells of 1 m, buildings with their glass and their rooms), the tiles to about 1 km with 4 m cells and buildings without glass, the rest to 2.2 km with 16 m cells and a box for each building. A city's roads are in the tile of the middle of their cell of the grid, at every level; their paint is left out at the last, and the kerbs are a level-0 tile's. A road between cities is cut at the tiles' sides, and lies on each tile's own ground. Trees are placements at every level (which plant of the library, where, how turned): the far ones are the voxels the plants already have. A tile's ground has a skirt down its sides, which hides the step to a neighbour of another level; neighbours of the same level share their edge's heights and normals exactly, because both ask the same function at the same places.

A tile is a file once made (`~/Library/Caches/MetalRenderer/generated/world-<seed>-v<version>/<level>/<x>_<z>.tile`, a section file: its meshes' arrays, its materials, its trees: the plants standing on it), keyed by the world's settings and versions. A city's tile is keyed by the share of its windows that are lit as well, and has its lights (see "The day and the night" below); the country's is the same whatever that share is. For the custom tracer the file also has the tree over each of its meshes, as the bytes the tracer's buffer holds (the nodes, then the triangles in the leaves' order): built when the tile is made, or added to a file that Metal's tracer left without them, and then never again. The files count against the cache's cap like the rest of that folder (`METALRENDERER_CACHE_MB`): a tile read is marked as used, and the first one written in a launch starts the sweep of the files used longest ago (before, only an unoptimised build's caches started it).

**The scene** (`Scene+World.swift`) is one moment of the world: the 289 tiles around the camera's. When the camera is a quarter of a tile into another one, the renderer makes the scene around that one in the background (the tiles the two share are kept, the new ones come from their files or are made) and swaps it in; what the frames have gathered (the upscaler's and the denoisers' histories) holds, since the world is in the same place. The scene's own instances are the tiles' chunks and the ground cover; a tile's trees are a group of instances with a name (`Scene.InstanceGroup`), which the scene only makes if the renderer doesn't have it.

**A tile crossing costs no frame.** Everything of the next scene is made off the main thread, and the swap between two frames takes 0.1 ms:
* **The scene's buffers and structures are made where the scene is** (`SceneBuffers.swift`): geometry, instance records, and for Metal's tracer the acceleration structures, built on a command queue of their own (the frames' queue runs its command buffers in order, and a frame would wait behind a build).
* **A mesh keeps its structure from scene to scene.** A tile's chunk or a plant of the library is the same triangles in every scene that has it, and says so by a name (`Scene.meshNames`); Metal's per-mesh structure of a named mesh is handed to the next scene. A crossing builds the 43 meshes that are new (100 MB as built, 50 compacted) instead of all 370 (760 MB).
* **And its buffer.** Such a mesh is in a buffer of its own (`MeshBlock` in `SceneBuffers.swift`): its positions, normals, UVs, indices and its triangles' materials one after the other; on the custom tracer a second buffer has its tree, the nodes and then the triangles, copied from the tile's file. The next scene takes the blocks of the scene being drawn by their names and fills only the new ones, and a block goes when the last scene that has it does. A hit finds a mesh's vertices through an address in the mesh table (`MeshData.block`), the custom traversal finds its tree through an address in the instance's record (where a mesh of the scene's own buffers has its root's number). Both are compiled in only for a scene with such meshes (`STREAMED`, with the scene's light types): the other scenes trace the code they did and render the same images, bit for bit, and so does the world with safe math (`METALRENDERER_MATH=safe`; with fast math the other code rounds differently: 0.006 levels RMS on the custom tracer, 0.11 on Metal's).
* **And a tile's trees stay as they are.** They are the same instances in every scene that has the tile, at any level of detail, for as long as the scene's origin stays; the renderer keeps what it made of a group in a block (`InstanceBlock` in `SceneBuffers.swift`), and a crossing makes the blocks of the 17 tiles that are new: 22,000 trees of 360,000. (Every plant of the library is added to a scene first, in the library's order, so a block's records name the same meshes and materials in the next scene.) Either tracer keeps one structure over all of a scene's instances, so what a block holds is its part of that:
  * **Metal's tracer:** the block's records in a buffer of its own, and its instances' descriptors. The next scene copies its blocks' descriptors into one buffer (52 MB) and builds its structure over them, in the background as before. A descriptor carries its instance's id (the block's number and the instance's place in the block), a hit returns it (`user_instance_id`) and finds the record through a table of the blocks' buffers (`TILED`, compiled in for such a scene only). An id is the same in every scene, so what goes by it (which leaves let the light through) no longer changes at a crossing.
  * **The custom tracer:** the block's tree over its instances, built once. The scene's tree is built over the scene's own instances and the parts of the blocks' trees, of at most 16 instances each (50,000 leaves, not 380,000), and the blocks' nodes are copied behind it with their numbers moved, so a ray walks one tree with the code it had. The records are in one buffer for the scene, as in any scene: the blocks' are copied from the buffer of the scene before (77 MB), and the block has them there from then on.
* **And a tile's meshes come with their trees**, on the custom tracer: the tile's file has the tree over each of its chunks (`WorldTile.addTrees`, `Scene.BorrowedTree`), and the mesh's block copies it from the mapped file into its buffer. A crossing builds no mesh's tree: the tracer's part of a scene takes 33 ms instead of 135 to 150, and the builder's scratch memory (0.3 GB that the allocator kept) is never asked for. The trees are the builder's own, byte for byte, so the pictures are the ones they were (0.0 of difference from the build before, with the cache and without). A tile never seen before has its trees built as it is made, on the thread that makes it, so the first visit costs what it did; later ones, and every launch, read them. The file is twice the size for it.
* **Nothing in the world moves**, so its instances are written once and Metal's structure over them is built once, in the background, for tracing rather than for a fast build and refits. That goes for every scene in which nothing moves (`Scene.isStill`): the Forest, the City and the Valley trace 9 to 13% faster on Metal's tracer for it (3.02 → 2.68, 2.03 → 1.85 and 1.77 → 1.54 ms), the world 30 to 35% (5.4 → 3.7 ms from the start). Their pictures on that tracer differ from before in the pixels where two surfaces coincide (another tree picks the other one: at most 0.15 levels RMS, fewer than one pixel in ten thousand more than 8 levels off).
* **The textures stay as they are streamed**: every scene of a world has the same textures in the same order, and takes the streamer and what it has mapped from the scene before. (A new streamer's first frame spent 25 ms in the kernel mapping its tiles.)
* **The buffers are used once before the swap** (a copy of a few bytes from each, on the build queue): the first command buffer to name a buffer pays for bringing it into the GPU's memory map, 5 to 12 ms for these, and that would be a frame.
* **The replaced scene is let go of on another thread**: freeing its buffers and arrays took 13 ms.

**Memory.** A scene borrows its tiles' meshes instead of copying them (`Scene.BorrowedMesh`): a tile's arrays are its file's pages, mapped, and the renderer copies them from there straight into the mesh's block, once, and the mesh's tree for the custom tracer from the same file into its buffer (a mesh that comes without a tree, a baked plant, has it built from the block and written straight into that buffer). The plants' baked meshes are lent the same way by the library, which is kept from scene to scene. So at a crossing only the new tiles are added to what the GPU holds, and the peak is the scene, the new tiles and a second structure over the instances (with, on the custom tracer, a second set of records); before the tiles had buffers of their own it was two whole scenes. The scene itself no longer has an array of its trees: 0.3 GB less at any time. Under Metal 4 the residency set lets go of a replaced scene's buffers eight frames after the swap, not 600: it held every scene of the flight below, 14.9 GB at the peak against Metal 3's 8.1.

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
| Custom tracer, at first | 34 ms | 54 ms | 509 ms | | 8.2 GB |
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
| A frame in flight, 640×400 → 1920×1200, cascades | 8.1 ms on the custom tracer, 3.8 ms on Metal's |
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
* A crossing still builds the structure over all the scene's instances: Metal's from 52 MB of descriptors copied together (25 ms of the GPU, with two structures held for a moment), the custom tracer's from the tiles' parts, with 77 MB of records copied and 23 MB of nodes for each frame slot. Only a structure per tile under the scene's would leave a crossing its new tiles alone, and that costs every frame (see "Ruled out"). The ground cover is made again with every scene. That, the new tiles' meshes and the scene itself (0.01 to 0.02 s) are the 0.07 s above, on either tracer.
* A tile never seen still has its trees built at the crossing that brings it into sight (0.07 to 0.25 s of the custom tracer's crossing, in the background), and its file is twice as large with them: the cache's 4 GB hold the tiles of about 12 km of flight.
* Lights come on by material: a building's lit blinds together, and all the lit rooms of a chunk. A window that is lit is lit all night.
* While the scene has the lights and the sun is the light, ReSTIR runs for the sun alone; and a sun near the horizon is dear on either path, its shadow rays crossing the whole scene. Sunset and sunrise are the dearest frames of the day.
* The eye's adaptation is a curve, the moon is always full, the stars don't turn, and no cloud is lit from below after the sun has set for the ground.
* At night a street's lamps go on as its tile comes within 1 km, and the windows of the tiles beyond the camera's neighbours light nothing but by GI; ReSTIR draws lights for pixels no light reaches.
* A road joins two cities only if their cells are next to each other: a city with no such neighbour has no road out of it. Roads meet nowhere but in a city, and there is no bridge and no tunnel: a road crosses a valley on a bank and a hill in a cutting, and is up to 19% steep. Every street is 12 m and every road between cities 8 m, with no cars, no signs and no traffic lights. A field is a colour and its rows: the wheat doesn't stand.
* Outside the fields the ground changes material in cells: 1 m next to the camera, 16 m at the edge of sight.
* GI sees no sun shadows beyond 384 m of the camera.

### Glass

Window glass is thin and clear, or tinted: the camera sees through it and sees its mirror reflection, and to light it isn't there.

* Glass is an instance mask (`Scene.maskGlass`); its material's albedo is the tint. Shadow, GI and reflection rays only meet geometry, so sunlight falls into rooms and a room's lamp lights the pavement, with no change to those kernels.
* `traceKernel`'s camera ray doesn't meet it either: the G-buffer holds the surface behind the pane, so direct light, GI, ReSTIR, the denoisers and the reflection pass light and filter that surface as usual.
* `glassKernel` (`Shaders/Glass.metal`) runs right after the trace: the camera ray again, against the glass alone, as far as the surface the trace found. For up to 4 panes it multiplies what comes through, (1 − Fresnel) × tint each, into the G-buffer's albedo, F0 and emission; for the first pane it traces one mirror ray, lights its hit with one light sample, and adds Fresnel × that to the emission.
* It is compiled in only for scenes with glass (a bit of the light-type constant), so every other scene draws what it drew, bit for bit, at the same speed.
* **Why a pass of its own:** `traceKernel` is short of registers. With the panes' rays inside it, every pixel of the city traced at a third of the speed (13.6 ms a frame from the road against 10.4); with only the ray through the panes inside it, as one call in a loop, the two kernels together were still 0.3 ms slower. One glass mesh per wall instead of per building changed nothing.
* **Cost:** 0.2 to 1.9 ms by day (the table above), more at night, when the mirror ray's hit draws its light from the light table.
* **Limits:** no refraction; glass doesn't tint or dim the light that passes it; the reflection's one light sample is filtered only by the upscaler (among many lights it is held low, so a dark pane doesn't sparkle); reflections off other surfaces see the room, not the pane.

### Geometry debug views

The View popup and key 9 cycle six views of what the primary rays hit. They run as a separate pass (about 2 ms at 1280×800) only while shown, so normal frames don't pay for them. Colours are shaded by the facing ratio so shapes stay readable.

| View | Shows |
|---|---|
| Triangles | A random colour per triangle, for all geometry. Virtual triangles keep their colour when the cut's BLAS is rebuilt. |
| Clusters | A random colour per virtual-geometry cluster (up to 128 triangles); other geometry is grey. |
| Groups | A random colour per cluster group, the unit the DAG simplifies and streams. |
| LOD level | The cluster's DAG level on a blue (finest) to red (coarse) scale: finer near the camera, coarser far away. Generated plants: blue where their triangles are traced, green, orange and red for the three voxel levels. |
| Triangle size | Projected edge length in traced pixels: blue ⅛ px, green 1 px, red 8 px and more. Virtual geometry at the default error is mostly green-yellow; full-detail meshes are blue (sub-pixel triangles). |
| Traversal cost | Node visits plus half the triangle tests of each primary ray, log scale: blue few, red ~500. Custom tracer only; Metal's intersector can't be counted, so the view is magenta. |

With the Metal tracer, the clusters, groups and LOD views are grey, because Metal traces full-detail meshes. The views work in both virtual-geometry runtimes. In `METALRENDERER_VG_MODE=clusters`, cluster colours follow a cluster's place in the page pool, so they change when it is streamed again.

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
       virtual geometry (background thread): Nanite cut per instance -> SAH BLAS over the cut where it changed
GPU 0  textures: map + upload the mip levels last frame's hits asked for (sparse textures), unmap unused ones
GPU 1  custom RT: rebuild the moving instances' top-level BVH (prep -> Morton keys -> sort -> hierarchy -> boxes);
       static geometry and the shapes of lights that stay in place are in trees built once
       (Metal RT instead: refit the instance acceleration structure, rebuild it every 16 frames; a scene in
       which nothing moves has one, built with the scene)
    1a regirBuildKernel  many lights: the light grid, per cell (2 levels x 16^3) 32 reservoirs of 8 table draws by
                       luminance toward the cell, from this frame's lights (ReSTIR DI's, GI's, the reflections' and
                       the fog's light samples draw from it)
    1b lightMapKernel  per-light distance maps (radiance cascades, path tracer with light maps)
    2  traceKernel     primary ray -> G-buffer (normal, depth, albedo, emission, motion, world position)
                       direct (up to 4 lights): 1 shadow ray per light (+ per-light visibility and penumbra width)
                       indirect (path traced): cosine-sampled path, NEE at every bounce
                       (lighting is stored without albedo so the denoiser can blur it freely)
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
                       -> drawable (sRGB format: the GPU encodes), or with upscaling linear colour at render resolution
    6  upscale         taauKernel straight into the drawable, or MetalFX into a private texture + a copy
```

With radiance cascades, 2b and 3–4 don't depend on each other. The frame then uses one concurrent compute encoder and runs them in lock step, with a barrier after each step: light map + trace + probes, then temporal + the top cascade, each à-trous pass + the next cascade down, and so on. Small dispatches on M1 leave the GPU partly idle, so this overlap saves about 0.2 ms. The path tracer runs in order.

| File | What it holds |
|---|---|
| `Renderer.swift` | Metal setup, scene loading, the frame (its plan, its stages, their encoding), input; Metal's acceleration structures when that tracer is selected |
| `Pipelines.swift` | The shader compile and every compute pipeline as one set, built in parallel off the main thread; the big kernels' variants with a configuration's flags compiled in |
| `BVH.swift` | The custom ray tracer's node format and CPU builder (binned SAH) for bottom-level and static top-level trees |
| `CustomRayTracer.swift` | The custom ray tracer's buffers, the per-frame GPU build of the moving objects' tree, its argument buffer |
| `Settings.swift` | Every user-adjustable setting, with defaults and ranges |
| `SettingsTable.swift` | Every setting once: its place in the settings, its `METALRENDERER_*` name and its panel row |
| `SettingsPanel.swift` | The Render Settings panel, built from the table |
| `SettingsStore.swift` | Saves and restores the settings between launches |
| `SettingsEnv.swift` | The settings as `METALRENDERER_*` variables, both ways: Copy as Env and the parser, from the table |
| `GPUProfiler.swift` | The Debug window's GPU pass timings (timestamp counters at encoder boundaries) |
| `DebugPanel.swift` | The Debug window: frame graph, pass timings, scene, virtual geometry, textures, memory, traversal counters |
| `Upscaler.swift` | MetalFX temporal (or spatial) scaler and the sub-pixel jitter sequence |
| `TemporalUpscaler.swift` | The custom upscaler's history textures and dispatch (`taauKernel`) |
| `RadianceCascades.swift` | Radiance cascades: probe textures, radiance atlases, per-frame passes |
| `BlueNoise.swift` | Void-and-cluster blue-noise generator, and the tile's cache file |
| `CacheFile.swift` | Where the app keeps what it derives (`~/Library/Caches/MetalRenderer`) and how it writes it; the launch timer |
| `SectionFile.swift` | Cache files of arrays behind a table of sections, and the generated scenes' cache folder (its names, its cap) |
| `Benchmark.swift` | Benchmark mode (`METALRENDERER_BENCH`): a setting of a run (`Config`), the frame clock, timing table and PNG capture |
| `Benchmark+Modes.swift` | The benchmark modes: each one's list of settings |
| `Scene.swift` | The Cornell, stress and gallery scenes: meshes, materials, instances, animation paths; the light types, their poses and visible shapes, shadow-denoiser groups, emissive-mesh lights and the light table; glTF models and their lights |
| `Scene+Lights.swift` | The six light demo scenes, the Misty hall and the fog volumes, the Open valley, the Night market, and the light-check scene the `lightcheck` benchmark renders |
| `Scene+Forest.swift` | Generated plants in a scene (`Flora`: materials, textures, assemblies and their wind bones) and the Forest |
| `World.swift` | The open world as a function of a seed and a place: ground, cities with their blocks, roads and fields, the roads between cities, where trees and ground cover stand; its day (`Heavens`: the sun, the moon, when the lights come on) |
| `WorldTile.swift` | A tile of the world at a level of detail: its meshes (and the custom tracer's trees over them), its trees, its lights, its file |
| `Scene+World.swift` | The Open world scene: the tiles around the camera's, which tile that is, and by night the nearer tiles' lights |
| `SceneBuffers.swift` | A scene on the GPU: its geometry's buffers, its instances' records, Metal's acceleration structures; made off the main thread. `MeshBlock`: a borrowed mesh's buffer, which scenes share. `InstanceBlock`: a group of instances, likewise |
| `Foliage.swift` | The plant generator: recipes, the grower, leaf, card and bough distributors, the plant library |
| `FoliageSpecies.swift` | Each species' recipes, by age, and its boughs' |
| `FoliageMesh.swift` | Stems, leaves, cards and grass as meshes; a plant baked into plain meshes; the mesh checks |
| `FoliageTextures.swift` | Generated textures: bark, leaves, grass, and the leaf cards' pictures and alpha masks |
| `FoliageVoxels.swift` | The plants' voxel grids for the distance level of detail, made from the library's plants for both tracers |
| `VoxelGrids.swift`, `VoxelLOD.swift` | Metal's tracer: the grids as one-box structures per level, and far plants' levels, picked as the camera moves and built into another instance structure in the background |
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
| `GLTFLoader.swift` | glTF 2.0 (`.glb` / `.gltf`) parsing: accessors, node hierarchy, metallic-roughness materials, images, punctual lights |
| `MaterialTextures.swift` | Whole textures, decoded at a capped size (when streaming is off or unsupported) |
| `TextureStreamer.swift` | Texture streaming: mip-chain caches, sparse textures, feedback, mapping and uploads |
| `MeshClusterizer.swift` | Clusters (≤128 triangles) by region growing, and cluster groups |
| `MeshSimplifier.swift` | Quadric half-edge-collapse simplifier with locked borders and seam-aware attribute handling |
| `VirtualGeometryBuilder.swift` | The cluster LOD DAG, cluster pages and the cache file format |
| `VirtualBLAS.swift` | Virtual geometry at run time (default): the cut per instance and a background BLAS over it (spliced from the clusters' BVHs, then SAH) |
| `VirtualGeometry.swift` | The GPU-driven variant (`METALRENDERER_VG_MODE=clusters`): GPU cut, page pool and streaming, cluster tree |
| `GPUTypes.swift` | Structs shared with the shaders. Their layout must match `Shaders/Types.metal` |
| `ShaderSource.swift` | Joins the shader files into the one source the runtime compiler takes, with `#line` markers so a compile error names the file and line |
| `Shaders.metal` | The shaders' entry file: the header and the list of pieces, in the order they build on each other |
| `Shaders/*.metal` | All GPU code, one file per subject: `Types`, `Sampling`, `Intersect`, `Surface`, `Lights`, `Regir`, `LightSampling`, `Fog`, `Sky`, `Trace`, `Glass`, `RestirDI`, `RestirGI`, `Reflections`, `Denoise`, `Output`, `RadianceCascades`, `BVHBuild`, `VirtualGeometry`, `Foliage` (the wind), `Crowd` |

## Notes for M1 / M2 Macs

M1 and M2 have no ray tracing hardware, so Metal's intersector is software too, and the ray budget is the main cost here. That is also why this project's own BVH traversal can beat it (see the stress test). On M3 and later it is the other way round: see "Hardware ray tracing, MetalFX's denoiser and Metal 4" below.

* By default the frame is traced at 0.5× the window size in points and upscaled 3× (1280×800 points → 640×400 traced → 1920×1200). Press `-` or `=` to change the traced resolution, and **U** to change the upscale factor.
* MetalFX temporal upscaling works on M1. With path-traced GI, the default resolution setting costs about 6.0 ms of GPU time on an M1 Max (custom upscaler), against 43 ms for a native 1920×1200 frame and 11.5 ms for a 960×600 frame stretched to the window. The stretched frame matches or loses to the upscaled one on image quality. If the GPU doesn't support MetalFX, the app renders at 0.75× without upscaling.
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
* **Stress test** (M1 Max, radiance cascades and the custom upscaler 3× from 640×400 unless noted; whole-frame GPU ms, best of two `METALRENDERER_BENCH=stress` runs with `METALRENDERER_BENCH_SPLIT=0`). "Before" is one shadow ray per light with the TLAS rebuilt every 256 frames; the next row adds the 16-frame rebuild; "now" adds light sampling with reuse and the lighter spheres. All of these were measured with Metal's acceleration structures, before the custom ray tracer, which takes 1.9–3 ms off the busier rows (see "Custom ray tracing vs Metal's" below):

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
  * "is this the same surface?" with named tolerances, last frame's pixel of a pixel (3), the pixel that shows a path's hit (3), the disk neighbour and the pairwise MIS weights of the two spatial reuse passes, the edge-stopping weights of the two à-trous filters, the Karras split of the two tree builders.

  The helpers compute what the copies computed: with `METALRENDERER_MATH=safe` on both sides, all 224 images of eight benchmark suites (`stressq`, `restirq`, `gi`, `fog`, `marketq`, `speccheck`, `restirgicheck`, `vgdebug`) match the previous commit's bit for bit. Whole frames, three alternating rounds against the previous commit, median change over a mode's settings:

  | Mode | Settings | Median change | Range |
  |---|---|---|---|
  | `restir` | 22 | −0.01 ms | within the noise of the cascades' resolve pass |
  | `stress` | 15 | +0.02 ms | −0.03 … +0.35 ms |
  | `fog` | 43 | +0.01 ms | −0.24 … +0.14 ms |
  | `gi` | 36 | +0.03 ms | −0.09 … +0.30 ms |

  * In `gi`, the full-budget ReSTIR GI settings are 0.10–0.15 ms (1.2–1.9%) slower and the high-quality cascades 0.03 ms (1%), in every round. No helper accounts for it: putting any one back by hand, or all of a kernel's, leaves the frame within ±0.1 ms of where it was, forcing the helpers inline makes it slower (+0.21 ms), and the previous commit's shaders with one never-taken extra call in a kernel the benchmark doesn't even run are slower by the same 0.1 ms (1.2%). The helper files alone, with the old kernels, cost nothing (0.00 ms). So this is how the compiler's module-wide decisions fall for a given source, not a cost of a helper: expect any shader edit to move unrelated kernels by about 1%, and judge a change of that size against a control edit (`measuring.md`).
  * Left different on purpose, because making them alike changes images: next-event estimation at a path's hit (the path tracer, ReSTIR GI and the reflections take their branches in different orders; the cascades' and the path tracer's light-map branch draw 8 candidates and clamp, the others 4 and don't), the ambient fixed point (1024 in the cascades, 256 in ReSTIR GI), and a light sample's distance floor (1e-6 at surfaces, 1e-4 in fog). The two bottom-up fit kernels keep their own walk-up loops (device-scope fences around a coherent pointer).
* **Load time: the glTF parser and the BVH builder** (October 2026; M1 Max, the gallery's 11 models, 17.9M triangles):

  | Step | Before | After |
  |---|---|---|
  | Models parsed, virtual geometry on (the default) | 0.4 s | 0.2 s |
  | Models parsed, virtual geometry off | 0.7 s | 0.4 s |
  | The custom tracer's BLAS, virtual geometry off (9.7M nodes) | 2.1 s | 1.5 s |

  * The parser reads 32-bit float positions, normals and texture coordinates straight into their vectors (no intermediate array, no type test per component), and the index type is tested once, not per index.
  * The builder bins a node's primitives along the three axes in one pass instead of three (the trees: 1.6 s to 1.3 s), and each mesh's nodes are written to their own range of the node buffer in parallel (0.36 s to 0.12 s). The parallel loops that took a lock to store a result write to their own slot instead.
  * The BLAS is the same, byte for byte (a checksum of its nodes, triangles and roots against the old builder's), and `METALRENDERER_RT_CHECK=1` finds no mismatch in 50000 rays.
  * A range of more than 32768 primitives now builds its two halves at the same time, and `BVHTests` checks that the tree is the single-thread one, node for node. It doesn't show in the gallery, whose eleven meshes already keep every core busy; it is there for one big mesh (not measured yet).
  * What didn't help, and is not in the code: an exact split for nodes of up to 12 primitives without the bins (the same tree, the same 1.5 s). Keeping the boxes in tree order, so a node reads a contiguous range, measured the same as reading them through the index array.
  * Still open: with virtual geometry off the BLAS is 1.5 s of a 2 s load, which is what a disk cache of it would remove.

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
  | A smaller traversal stack | 48 and 128 entries instead of 64 | ±0.03 ms (stress hall, 8.6–18.3 ms frames) |
  | | 32 entries | +1.8 to +3.5 ms: 20% slower |
  | Trace's writes that a later pass overwrites | no indirect write with the cascades or ReSTIR GI, no direct write with ReSTIR | −0.01 ms (cascades), ±0.05 ms (ReSTIR) |
  | The sky's ambient light, computed once | a constant in place of the two sky samples (the most it could save) | 0.00 ± 0.01 ms (fog scenes) |
  | One atomic add per SIMD group | `simd_sum` in the cascades' SH pass, instead of four adds per probe | 0.00 ± 0.02 ms |
  | The filters' normal weight | 6 or 7 squarings in place of `pow(x, 64)` and `pow(x, 128)` | −0.10 to +0.27 ms, no pattern |
  | The filters' colour sums in `half` | à-trous and the shadow filter | −0.06 to +0.02 ms |
  | The temporal pass's fallback for new pixels | removed (the most a cheaper one could save) | 0.00 to +0.06 ms |

  * The stack's result is the one worth remembering: 64 entries cost nothing over 48, and below some size the compiler handles the array differently and every ray pays. What the audit was right about is that a full stack skips a subtree silently, so the traversal counters now count those pushes (`RT_STATS`, the Debug window's Ray traversal section, and a benchmark's line with `METALRENDERER_RT_STATS=1`). No scene has any: the stress hall, the market at 16384 bulbs, and the gallery in each of its three geometry modes.
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
* **Custom ray tracing vs Metal's** (M1 Max, stress scene, 32 lights, moving, custom upscaler 3× from 640×400).
  * Whole frames (`METALRENDERER_BENCH_SPLIT=0`, two alternating runs each):

    | | Metal | Custom |
    |---|---|---|
    | Cornell room, default | 2.40–2.45 ms | 2.34–2.52 ms |
    | Stress, 2000 objects, radiance cascades | 12.59 ms | **9.60 ms** |

  * Per pass (`METALRENDERER_BENCH=rt`), Metal → custom:

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
    * **Static objects stay instances** in their own tree, built once, as with Metal (merging them into one mesh loses the walls' tight boxes).
    * **Lights that stay in place are static too.** A light says what of its pose changes (`Scene.LightMotion`: animated, scale only, constant), and only an animated light's shape is a moving instance. In the Night market that leaves 140 of 17329 instances in the per-frame tree at 16384 bulbs: the tree build drops from 0.29 to 0.07 ms, the whole frame by 0.30 / 0.38 / 0.62 ms at 1024 / 4096 / 16384 bulbs, and the CPU's work per frame from 0.63 / 0.86 / 1.73 to 0.37 / 0.43 / 0.64 ms (the `cpu` column; the images are bit-identical). The static shapes get their own tree next to the geometry's, under one root: shadow and GI rays skip it there by its mask. One tree over both cost those rays 0.5 ms at 16384 bulbs, because the SAH then splits the geometry around the bulbs.
  * What didn't help:
    * Skipping postponed subtrees that start beyond the closest hit (a second stack of entry distances) cost 15%: the extra stack traffic outweighs the boxes it skips.
    * A smaller stack (32 entries) changed nothing.
    * Bigger leaves (a higher SAH traversal cost) were 2–4% slower.
    * A watertight triangle test (Woop et al.) was 30% slower and changed no image. The upscaled moving frames that differ from Metal's along silhouettes come from depth and motion differing in the last float bits, which the upscaler's depth-edge and clip decisions amplify; native frames match bit for bit.
    * An SAH-built moving-object tree (`METALRENDERER_RT_BUILD=cpu`) traces only 4–7% faster than the GPU LBVH.
    * Writing the per-frame instance and light records straight into the shared buffers (to skip a copy) cost the GPU 0.35 ms a frame at 16384 moving lights: records written one by one stay in the CPU's caches. The renderer keeps them in arrays of its own, rewrites only what moved, and copies each array to the frame's buffer in one go.
    * Relaxed instead of fast shader math (`METALRENDERER_MATH=relaxed`) renders the same images and costs 0.2 ms a frame in the stress hall, so fast math stays; the shaders test for "no hit" with a comparison (`isFar`) that fast math can't fold away.
* MetalFX's built-in denoiser (`MTLFXTemporalDenoisedScaler`) also runs on an M1 Max under macOS 27, but it costs 4.2 ms at 640×400 → 1920×1200. That's more than this project's SVGF denoiser plus the temporal scaler it would replace (about 1.5 ms together). It is now an upscaler option (`upscaler=denoiser`); the next section has its numbers on an M4 Max.

* **glTF gallery** (11 Tripo models, 17.9M triangles, 67 textures of up to 4096², M1 Max, 640×400; `METALRENDERER_BENCH=gallery`, `Tools/eval/gallery.py`).
  * Virtual geometry against full-detail meshes, same scene and custom tracer (GPU ms per frame):

    | | Full detail | VG 1 px | VG 2 px |
    |---|---|---|---|
    | Triangles traced | 17.9M | 0.4M (overview), 1.1M (close-up) | 0.18M |
    | Geometry memory | ~1.5 GB (BLAS + vertex buffers) | 40 MB (overview), 108 MB (close-up) | 18 MB |
    | Overview, direct light | 4.33 | 4.09 | 3.81 |
    | Camera fly-through (3× upscaled) | 16.63 | 17.54 | — |

    About the same speed, at 3–4% of the memory. The cut updates in the background in 30–150 ms when it changes (the fly-through rebuilt 900 instance BLASes). Quality: the cut is crack-free and looks the same. Against path-traced references it scores 29.7 dB at 1 px, 31.5 dB at 0.5 px and 35.0 dB at full detail on the overview; the single sample per pixel makes texture detail alias, so sub-pixel geometry changes cost dB there (blurred 4×4, VG 1 px and full detail agree to 41 dB).
  * PBR against the path-traced references (close-up, full detail): 30.8 dB with cascades, 31.6 dB path traced. Average colour per region matches within 0.5% on the glossy floor, 1–3% on the steel plinths, about 5% on the bronze owl. The reflection pass costs 0.4 ms on a still frame and 0.6–1.0 ms in motion.
  * Texture streaming: 14 MB resident from the overview and 46–65 MB close up, against 2.6 GB for all levels (or 711 MB capped at 2048). Images match fully resident 4K textures at 56–77 dB. Uploads are capped at 48 MB per frame.
  * What mattered:
    * **One SAH tree per model over the cut, not a tree of clusters.** The first runtime selected the cut on the GPU, streamed cluster groups into a 768 MB pool (buddy allocator, LRU, Nanite's residency rules) and built a per-frame LBVH over the selected clusters, each with its own little BVH. It works (`METALRENDERER_VG_MODE=clusters`) but traces 2× slower than full detail. Rays visit 8.6 nodes per ray inside models instead of 3.8, because cluster boxes overlap. Splitting the tree per instance to drop the per-cluster transform changed nothing, and an offline SAH over the same clusters would only save 15%.
    * **Simplification that keeps going:** locking only group borders (not the mesh's own open edges), letting seam and border vertices slide along their seams, a relaxed pass across UV seams for fragmented Tripo atlases when the strict one gets stuck, passing stuck groups up a level, and filling clusters spatially. That took the DAG from 883 root groups per model (full-detail fragments, always drawn) to one 366-triangle root, and the cut from 62k clusters to 3.9k.
    * **Texture levels from the largest UV stretch** (as GPUs do) and a histogram instead of a minimum: UV slivers and close self-reflections had asked for 4K mips of models 100 px tall (600 MB resident instead of 14).
  * In close-ups, Metal's intersector on the full-detail meshes is about 12% faster than this tracer with virtual geometry (11.1 vs 13.7 ms); from the overview, and in the stress scene, the custom tracer is faster.

## Hardware ray tracing, MetalFX's denoiser and Metal 4

Three options for GPUs and systems that have them, each checked at launch (`Capabilities.swift`) and off by default:

* **Ray tracing: Metal** (`METALRENDERER_RT=metal`). Metal's acceleration structures and intersector, which M3, A17 Pro and later traverse in hardware. On macOS 26 the per-mesh structures are built for fast intersection (`MTLAccelerationStructureUsage.preferFastIntersection`) and compacted.
* **Upscaler: MetalFX denoiser** (`METALRENDERER_GI=upscaler=denoiser`, macOS 26). `MTLFXTemporalDenoisedScaler` takes the raw 1-sample light, linear and unbounded, with the albedo, the normals, a specular albedo and the roughness to guide it, and returns it denoised at the output resolution. It stands in for SVGF, the shadow denoiser and the upscaler; `tonemapKernel` then applies the exposure and the tone curve.
* **Graphics API: Metal 4** (`METALRENDERER_API=metal4`, macOS 26). The same kernels through Metal 4's command model (`Metal4Backend.swift`): an `MTL4CommandQueue`, command buffers reused with an allocator per frame slot, one unified compute encoder for dispatches, blits and TLAS updates, bindings through an argument table, a residency set in place of `useResource`, explicit barriers, pipelines from `MTL4Compiler` and MetalFX's Metal 4 scalers. The residency set drops what no frame has declared for 600 frames (and, eight frames after a scene is replaced, what no frame has declared since), so everything a kernel reaches through an argument buffer is declared every frame, the streamed textures included (they are placement-sparse textures, each its own allocation next to the heap). `METALRENDERER_RESIDENCY_LIFE=<frames>` shortens the 600, so that a resource nobody declares shows in a run of a thousand frames (`METALRENDERER_RESIDENCY_LIFE=16 METALRENDERER_SHOT_FRAMES=1000`): the frame that reaches it after it was dropped faults, and the log says which command buffer failed.

Measured on an M4 Max (macOS 26.5, 640×400 traced → 1920×1200, moving frames, rendered into a texture rather than the window's drawables).

**Whole frames**, GPU ms (`METALRENDERER_BENCH=hwrt METALRENDERER_BENCH_SPLIT=0`, two runs within 0.05 ms of each other):

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

**Image quality** (`METALRENDERER_BENCH=hwrtq METALRENDERER_RT=metal`, `Tools/eval/hwrt.py`; PSNR against supersampled references, flicker in 8-bit levels between two frames of a still scene):

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

**Metal 4 against Metal 3** (`METALRENDERER_BENCH=api`): the frames are bit-identical, for both tracers and all three outputs, in the Cornell room, the stress hall and the scenes with a sky. Whole-frame GPU time is the same within 0.01 ms (0.99 / 0.99, 0.78 / 0.78, 4.49 / 4.49 and 1.93 / 1.94 ms for the four rows of the mode); the CPU's encoding takes 0.01–0.02 ms more. Scenes with a sky cost 0.2 ms more (the valley: 1.53 → 1.77 ms, 1.20 → 1.42 ms with Metal's tracer), for the Metal 3 command buffer in the middle of the frame described below. So Metal 4 buys this renderer nothing yet: its frames were already one compute encoder with few bindings.

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

1. **Thin-feature locks for the custom upscaler:** in busy scenes it flickers 3× as much as MetalFX on still frames (see the stress test). Marking pixels where a thin, high-contrast feature keeps appearing and protecting their history from the clip, as FSR 2 does, would fix that.
2. **Many lights, sharper:** ReSTIR scales flat but stays below the grouped picker's quality up to 1024 lights, because SVGF blurs noisy radiance where the shadow denoiser only blurs visibility. The light grid made the candidates 2.4 dB better in the Night market, but SVGF turns that into 0.3–0.6 dB; a denoiser built for ReSTIR (ReBLUR or ReLAX-style, with the reservoirs' confidence as input) would blur less. The grid's cell target ignores orientation (so it stays unbiased); a conservative cone and facing test over the whole cell would drop the spots and rects that can't reach it, and a per-cell normal estimate from last frame's G-buffer would do better still. With the grouped picker, still frames still flicker more than with one ray per light; a denoiser that tracks the variance of fractional visibility over time is the likelier fix there.
3. **Faster custom traversal:**
   * Collapse the binary trees into 4-wide nodes, so a ray tests four boxes per fetch and pushes less. The GPU LBVH would need a collapse pass too, or the single loop would diverge again.
   * Give the LBVH SAH-quality top levels, for example with treelet restructuring or PLOC: a CPU SAH tree traces 4–7% faster.
   * With 2000 objects the frame still costs 1.4 ms more than with 400; sorting secondary rays by direction for coherence is the other thing to try.
4. **Better GI caching:** radiance cascades and ReSTIR GI's multi-bounce feedback fall back to the scene's average indirect light at points no screen pixel covers, and cascades lose 7 dB to the path tracer in cluttered scenes like the stress hall. A coarse world-space irradiance volume (or DDGI probes) would give those points real local values.
5. **Cheaper ReSTIR GI:** its paths cost what the path tracer's do, so it runs at 2–3× the cascades' cost. Half-resolution reservoirs (with full-resolution reuse), or paths that end in a world-space radiance cache after one bounce, would cut that. The multi-bounce feedback alone, which made most of its gain, could also be given to the plain path tracer. And a denoiser that uses the reservoirs' confidence (ReBLUR or ReLAX-style) might turn reuse's lower raw noise into a lower error, which SVGF doesn't.
6. **The crowd, further:**
   * Write the walkers' transforms on the GPU (instance data and Metal's instance descriptors), which is what the CPU still does per character and frame.
   * Metal's tracer pays per refitted structure: refit half the slots a frame, or build the poses' structures with Metal 4's own acceleration-structure encoder where it exists.
   * Pick a pose's level of detail by its nearest character's distance, with full-detail slots for the characters next to the camera.
   * Keep the bots' two materials (a material index per triangle), and read skins and animations from glTF too.
7. **Specular, better:** reflections reproject with surface motion, so glossy reflections smear a little in camera moves (virtual-point reprojection would fix that), and secondary hits treat specular as diffuse.
8. **Virtual geometry:** a GPU-built (or treelet-optimized) BLAS over the cut would let the cut update every frame; LOD cross-fades would hide the rare pop; the Metal tracer could build BLASes over the cut too.
9. **Texture compression:** ASTC or BC7 would cut the texture cache (2.5 GB) and streaming bandwidth by 4×.
10. **Rasterized G-buffer:** generate primary visibility with a raster pass to save one ray per pixel.
11. **Custom upscaler at 2× and 1.5×:** it matches MetalFX in motion at 3× but trails by up to 0.7 dB in camera moves at lower factors. Tuning per factor (its motion cuts are scaled by the factor today), or a per-pixel disocclusion test that doesn't misfire on jittered edges, would be the next step.
