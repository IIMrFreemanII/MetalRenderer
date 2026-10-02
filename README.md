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
  * an **Open valley** for the sky and clouds (see "Sky and clouds" below).
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
  * Each instance whose cut changed gets a fresh SAH BLAS over exactly those triangles, read from the memory-mapped cache, so the OS streams pages from disk.
  * Rays see one tight tree per model.
  * The gallery's 17.9M triangles trace as a 0.4M-triangle cut in 40 MB, instead of ~1.5 GB, at about the same speed (see below).
  * Debug views (key 9) show triangles, clusters, groups, DAG levels, projected triangle size and traversal cost. Freeze LOD (L) keeps the cut chosen for where the camera was, so you can fly up and inspect it.
* **Physically based materials:** GGX specular with Smith visibility and Schlick Fresnel for glTF materials; the generated scenes stay diffuse and unchanged.
  * Direct specular is exact per light (representative-point sphere lights), multiplied by the shadow denoiser's visibility in the composite.
  * Indirect specular comes from a reflection pass: one GGX visible-normal ray per pixel, divided by an analytic specular albedo and denoised.
  * References follow full paths.
* **Texture streaming:** textures are cached at full resolution with full mip chains and live in a sparse heap (budget 1 GB).
  * Primary hits count, per texture, the mip levels they need.
  * The streamer maps and uploads the finest level 1.5% of the samples need and unmaps levels nobody needed lately.
  * The gallery's 2.6 GB of 4K textures need 14 MB from the overview and 46–65 MB close up.
* **Direct light:** ray-traced soft shadows. With up to 4 lights, each light gets one shadow ray per pixel. With more, lights are split into 4 colour groups, and each pixel picks one light per group, weighted by how much light it would get from it unshadowed, then traces one shadow ray to it. That's 4 rays per pixel whatever the light count, but picking still weighs every light.
* **ReSTIR DI for many lights (default above 256 lights):** each pixel draws a few candidate lights from a power-weighted alias table in O(1), keeps one by resampling, and reuses last frame's and its neighbours' picks. The cost depends on the resolution, not the light count: 16384 lights cost 17 ms where 4096 lights cost 53 ms with the grouped picker (see "Many lights" below).
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
* **Settings panel:** a floating **Render Settings** panel (Tab or ⌘,) has a control for every setting, including the GI method and its parameters and the denoiser parameters. It remembers your settings between launches, copies them as `METALRENDERER_*` variables, and shows the resolution, frame rate and GPU time, optionally per pass (see [The settings panel](#the-settings-panel)).
* **Exposure and tone curves:** exposure in stops and a choice of ACES (the default), AgX, Reinhard or none, applied in the composite pass before any upscaler.
* **Everything runs in compute kernels.** `Shaders.metal` is compiled at runtime, so you can edit it while the app runs and press **R** to reload.

## Build and run

You need Xcode 15 or newer and macOS 13 or newer.

```bash
cd MetalRenderer
swift run -c release
```

You can also open `Package.swift` in Xcode, choose **My Mac**, and press Run. Use the Release scheme for real frame rates.

> The app finds `Shaders.metal` through its source path, so run it from this folder rather than copying the binary somewhere else.

### Benchmark mode

```bash
METALRENDERER_BENCH=1 swift run -c release
```

This runs a fixed animation through a list of settings (GI bounces, denoiser, render scale, MetalFX upscaling), times each GPU pass, prints a table, and quits. Set `METALRENDERER_BENCH_DIR=<folder>` to also save one PNG per setting. Use `METALRENDERER_BENCH=quality` to render the same frames natively and with MetalFX instead, so you can compare the PNGs. Use `METALRENDERER_BENCH=noise` to render white- and blue-noise sampling next to converged reference images, made by averaging thousands of frames of the paused scene. Use `METALRENDERER_BENCH=denoise` to render a few frames for scoring denoiser changes against those references. Set `METALRENDERER_DENOISE`, for example `passes=3,tpasses=2,sigma=2,history=16,antilag=1,separate=1`, to override the denoiser in every setting without rebuilding (`tpasses` is the pass count with cascade GI).

Each pass runs in its own command buffer so it can be timed, which serializes the whole frame. A pass that runs in more than one buffer per frame (reflections, composite with its reference averaging, MetalFX after TAAU) reports the sum; before October 2026 it reported only its last buffer. Set `METALRENDERER_BENCH_SPLIT=0` to encode frames exactly as the app does (one command buffer, with radiance cascades overlapping the denoiser) and report only whole-frame GPU time. `METALRENDERER_OVERLAP=0` turns that overlap off, for A/B timing.

Use `METALRENDERER_BENCH=shadow` to score direct-light denoising (static, moving and camera-move frames against a converged reference). Use `METALRENDERER_BENCH=upscale` to score the upscalers against supersampled native 1920×1200 references, on the albedo view and on direct light. `METALRENDERER_UPSCALERS=metalfx,custom,spatial` picks the upscalers, and `METALRENDERER_GI=upscaler=metalfx` switches every setting to one (`scale=0.75,factor=2` tests another upscale factor against the same references). Its "pan" frames fly the camera over the frozen scene; `METALRENDERER_PAN=rotate` makes that a pure rotation. `METALRENDERER_DENOISE` also takes `shadows=0` (SVGF for direct light), `spasses`, `shistory`, `sclamp` and `ssigma`. `METALRENDERER_GI` takes `blue` and the custom upscaler's `taau…` keys (see `Benchmark.swift`).

Use `METALRENDERER_BENCH=stress` to time the stress scene against light count (1 to 256), object count (0 to 2000) and GI method, and `METALRENDERER_BENCH=stressq` to score its direct light at 32 and 128 lights, and its final image, against converged references. `METALRENDERER_SCENE=stress,objects=400,lights=32` loads the stress scene in every setting of any mode. `METALRENDERER_LIGHTS=all` traces one shadow ray per light again (the brute-force baseline), `METALRENDERER_GI=lightrays=2` sets the shadow rays per light group, and `METALRENDERER_TLAS=<frames>` sets the rebuild interval of Metal's TLAS (1 = every frame; the custom tracer rebuilds its own every frame). `METALRENDERER_BENCH_ONLY="32 lights|camera"` runs only the settings whose names contain one of these strings.

`METALRENDERER_RT=metal|custom` picks the ray tracer for every setting. Use `METALRENDERER_BENCH=rt` to compare the two:
* It first renders paused frames in every GI mode on both scenes with the `METALRENDERER_RT` tracer. Run it once per tracer and diff the PNGs with `Tools/eval/pngdiff.py`.
* Then it times moving frames at 0–2000 objects, alternating the two tracers.

`METALRENDERER_RT_BUILD=cpu` builds the custom tracer's moving-object tree on the CPU with binned SAH instead of on the GPU (a better tree, for comparison). `METALRENDERER_RT_CHECK=1` checks every mesh's tree against brute-force ray/triangle tests at startup. `METALRENDERER_RT_STATS=1` compiles traversal counters in, and benchmarks print them per setting: nodes, instance and cluster entries, and triangle tests per ray.

Use `METALRENDERER_BENCH=gallery` for the glTF gallery. It renders path-traced references (full BRDF, full-detail meshes, 4 bounces; skip them with `METALRENDERER_GI_REFS=0`), then the overview and a close-up with full-detail meshes and with virtual geometry at 0.5, 1 and 2 px, alternating so heat affects them alike, and the camera fly-through. Score it with `Tools/eval/gallery.py`.

These variables apply to the gallery and to models in general:
* `METALRENDERER_SCENE=gallery` starts the app in the gallery; `model=<path>` adds a model, as File > Open does.
* `METALRENDERER_GALLERY="owl|demon"` loads only the matching files; `METALRENDERER_ASSETS=<folder>` uses another folder.
* Virtual geometry:
  * `METALRENDERER_VG=0` turns it off; `METALRENDERER_VG_TAU=<px>` sets the allowed error.
  * `METALRENDERER_VG_MODE=clusters` uses the GPU-driven cluster variant (see below), with `METALRENDERER_VG_POOL=<MB>` for its page pool.
  * `METALRENDERER_VG_SYNC=0|1` forces background or synchronous cut updates; benchmarks run them synchronously.
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
* `METALRENDERER_BENCH=lightcheck` cross-checks the closed-form area lights. A rect, a tube and a sphere light are each rendered over a floor next to an emissive-mesh twin of the same shape and radiance, converged over 1024 frames. The mesh estimator is unbiased, so the pairs should match:
  * the sphere matches its twin within 0.1%;
  * the rect within 1%;
  * the tube within 7%, which is the extra light from the capsule twin's end caps.

For many lights:
* `METALRENDERER_DIRECT=auto|exact|grouped|restir` picks the direct-light method (`METALRENDERER_LIGHTS=all` is `exact`).
* `METALRENDERER_RESTIR="candidates=8,chains=4,temporal=1,maxm=8,spatial=1,k=4,radius=24,vis=0,split=0,sigma=3,passes=4,history=8,boost=2"` overrides ReSTIR's settings (these are the defaults).
* `METALRENDERER_LIGHT_TABLE=1` or `0` forces the light-table shader variant on or off (normally on above 256 lights).
* `METALRENDERER_BENCH=restir` times the stress scene at 1 to 16384 lights with each method (exact up to 256, grouped up to 4096), then the Night market at 1024, 4096 and 16384 bulbs.
* `METALRENDERER_BENCH=restirq` renders direct light only (640×400) at 32, 128, 1024 and 4096 lights with each method, still and moving, against accumulated references (every light traced up to 1024 lights; above that, ReSTIR without reuse, which is unbiased). `METALRENDERER_BENCH=restircheck` accumulates ReSTIR without reuse against every light traced in each light-type scene, to check it's unbiased. `Tools/eval/restir.py` scores both.

For ReSTIR GI:
* `METALRENDERER_RESTIR_GI="quarter=0,bounces=2,lightmaps=0,feedback=1,dfeedback=1,fallback=1,temporal=1,maxm=2,age=30,spatial=0,k=2,unbiased=1,radius=30,dmin=0.02,denoise=1,sigma=3,passes=2,history=8,boost=2,antilag=0"` overrides its settings in every benchmark setting (these are the defaults).
* `METALRENDERER_BENCH=restirgicheck` accumulates indirect light (2 bounces, unclamped, no feedback) of path tracing against ReSTIR GI without reuse, with temporal and unbiased spatial reuse, and with the quarter budget, in the Cornell room and the stress hall. `Tools/eval/restirgi.py` scores it: the mean brightness ratios should be 1.00.

For the fog:
* `METALRENDERER_FOG=0` or `1` turns it off or on in every scene's preset.
* `METALRENDERER_FOG_SET="density=0.03,g=0.6"` overrides its settings. The keys are `on`, `density`, `falloff`, `base`, `g`, `ambient`, `noise`, `tile`, `far`, `volumes` and `reflections`.
* `METALRENDERER_BENCH=fog` renders each fog scene paused at t = 5 s with cascade GI. It renders fog off, the preset, no local volumes, no fogged reflections, path-traced GI and the scattering view, then moving frames (natively and 3× upscaled).
* `METALRENDERER_BENCH=fogcheck` renders the froxel grid against a reference that marches every camera ray in 32 steps, each with its own shadow ray, averaged over 512 frames. It renders direct light only, as the scattering view and as the final image, for the Misty hall, the spots and the sun scene.
* Both fog modes take `METALRENDERER_LIGHTS_SCENES`.

For the sky:
* `METALRENDERER_SCENE=valley` starts in the Open valley.
* `METALRENDERER_SKY=constant`, `atmosphere` or an image path overrides every scene's sky.
* `METALRENDERER_SKY_SET="coverage=0.5,wind=20"` overrides the clouds. The keys are `clouds`, `coverage`, `density`, `base`, `thickness`, `scale`, `erosion`, `wind`, `winddir`, `shadows`, `strength`, `exposure` and `over` (clouds over an image).
* `Tools/test-assets/make-test-sky.py out.hdr [elevation] [azimuth]` writes a synthetic equirectangular test sky with a sun.
* `METALRENDERER_BENCH=sky` renders the valley at morning, forenoon, noon, afternoon and evening, from the ground and from the air, plus the sun and mixed scenes. It adds clear-sky, no-cloud-shadow and constant-sky variants, then moving frames. It takes `METALRENDERER_LIGHTS_SCENES`.
* `METALRENDERER_BENCH=skycheck` renders the valley in the afternoon, with a cloud shadow's edge in view. Each GI method runs against a 4-bounce path-traced reference, for the final image and indirect light, with cloud shadows on and off.

The models in `Assets/` (596 MB) are stored with [Git LFS](https://git-lfs.com): install it before cloning (`brew install git-lfs && git lfs install`), or run `git lfs pull` afterwards. `.gitattributes` sends 3D models (`.glb`, `.fbx`, `.obj`, `.usd(z)`, `.blend`), HDR skies (`.hdr`, `.exr`) and the buffers and textures under `Assets/` to LFS. Put any glTF files there. The caches in `Assets/.metalrenderer-cache/` (4.4 GB for the 11 sample models: 1.9 GB of geometry DAGs, 2.5 GB of texture mip chains) can be deleted at any time; they're rebuilt on the next load.

Use `METALRENDERER_BENCH=gi` to compare the GI methods. It first renders 8-bounce, unclamped path-traced references by averaging thousands of frames of the paused scene; skip them with `METALRENDERER_GI_REFS=0` once you have them. Then, for each method, it renders a static frame, the next one (for flicker), an indirect-only frame, a moving frame, a frame at the end of a scripted camera move, and a frame with MetalFX on. `METALRENDERER_GI_MODES` picks the methods, for example `pt,pt-lightmaps,cascades,cascades-hq,restirgi,restirgi-q`. `METALRENDERER_GI` overrides GI settings everywhere, for example `mode=pt,bounces=4`, `mode=cascades,spacing=4,b1=0.25` or `mode=restir`. `METALRENDERER_TG`, for example `trace=16x8`, overrides a kernel's threadgroup size.

`Tools/eval/` scores the saved PNGs against reference images committed in `Tools/eval/refs/` (PSNR and flicker; see its README).

The benchmark renders frames back to back without vsync, so the GPU's clock stays steady. Long runs can still throttle as the GPU heats up, so compare timings from short runs. The lists of settings are in `Benchmark.swift`.

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
| B | Toggle blue-noise sampling (on by default; the tile is generated at startup, which takes about 0.5 s) |
| 1–8 | View: final, raw direct, raw indirect, normals, albedo, history length, indirect only, GI debug (cascades: probe grid over interpolation confidence) |
| 9, 0 | Cycle the geometry debug views (see below); back to the final image |
| L | Freeze LOD: virtual geometry keeps choosing detail for where the camera is now |
| R | Hot-reload `Shaders.metal` |
| ⌘O, drop files | Add glTF models (`.glb` / `.gltf`) in front of the camera, or an HDR sky (`.hdr` / `.exr`) |
| Tab, ⌘, | Show or hide the Render Settings panel |

The window title and the settings panel show the resolution, frame rate and GPU time. The panel never takes keyboard focus, so the keys above keep working while it's open, and changes you make with the keys show up in it.

### The settings panel

* **Sections** fold with their triangles; the panel scrolls and can be resized, and keeps the size you drag it to. Rows that don't apply to the current mode are hidden (the stress scene's object count, each GI method's parameters, ReSTIR's, fog's while it's off).
* **Show advanced** (at the bottom) adds every remaining setting: ReSTIR DI's chains, confidence cap, neighbours, radius, split visibility and its own denoiser; ReSTIR GI's light maps, multi-bounce sources, caps, radius, minimum distance and its own denoiser; the shadow denoiser's history, clamp and edge tolerance; the custom upscaler's history, colour clip, sharpness and motion cuts; fog's base height, noise tile, wind and albedo; the clouds' thickness, size, erosion, wind direction and shadow strength; an HDR sky's exposure; and a Memory section (geometry pool, texture budget).
* **Camera and time:** exposure (EV) and the tone curve, the field of view, the move speed, the animation's speed, and, in the sun and valley scenes, the time of day (an offset into the day cycle that moves only the sun and the sky; it works while paused). At their defaults (0 EV, ACES, 60°, 1×) images are bit-identical to before.
* **Denoiser:** a caption says what the generic rows (passes, σ, history, anti-lag) filter in the current mode. ReSTIR DI and ReSTIR GI filter their own signal with their own settings, under Show advanced in their sections.
* **Remembered:** settings are saved (UserDefaults) half a second after each change and restored at the next launch, except the pause, the view, Freeze LOD and added models. `METALRENDERER_SETTINGS=default` starts from the defaults instead. Benchmarks never read or write them.
* **Copy as Env** puts the `METALRENDERER_*` variables that reproduce the current settings on the clipboard, listing only what differs from the defaults (fog and sky from the scene's preset). They work in a normal launch, where they override the saved settings, and in benchmarks, where they apply to every setting. `METALRENDERER_DUMP_SETTINGS=1` prints the settings as JSON at startup, to compare two launches. The camera pose and where added models were placed aren't included.
* **GPU pass timings** lists each pass's GPU time, averaged over half a second. Each pass then gets its own compute encoder, timestamped at its start and end (Apple GPUs sample counters only at encoder boundaries), and the radiance cascades no longer overlap the denoiser, so the frame is a little slower while it's on. MetalFX, its copy into the drawable and texture streaming can't be timestamped; they show as "other", the frame's GPU time minus the timed passes.

The environment variables, in a normal launch and in benchmarks: `METALRENDERER_SCENE`, `METALRENDERER_GI` (now also `on=0` for GI off), `METALRENDERER_DENOISE`, `METALRENDERER_RESTIR`, `METALRENDERER_RESTIR_GI`, `METALRENDERER_FOG_SET` (now also `albedo=r:g:b` and `wind=x:y:z`), `METALRENDERER_SKY_SET`, and `METALRENDERER_VIEW="exposure=1,tonemap=agx,fov=70,speed=5,timescale=0.5,tod=0.25"` (plus `view=<index>` and `paused=1` outside benchmarks). The plain ones (`METALRENDERER_DIRECT`, `_RT`, `_VG`, `_VG_TAU`, `_VG_POOL`, `_SPECULAR`, `_TEXTURE_BUDGET`, `_FOG`, `_SKY`) set defaults, as before.

### Scene settings

| Setting | Default | Effect |
|---|---|---|
| Scene | Cornell room | Cornell room (5 objects, 2 moving, 3 lights), the stress test, the Gallery of glTF models in `Assets/`, or one of the light demos and the Misty hall (see below). Switching rebuilds the geometry and acceleration structures in the background, and picks that scene's fog and sky defaults (and resets the GI method to radiance cascades). Reset to Defaults also uses the current scene's. The gallery's first load builds its geometry and texture caches (about a minute for 11 models); later loads take seconds. |
| Objects | 400 | Stress test: objects in the hall, about 85% of them moving. Applied when you release the slider. |
| Lights | 32 | Stress test: moving sphere lights, 1 to 16384. Their total power stays the same, so the brightness barely changes; above 256 the bulbs also shrink. Night market: festoon bulbs, 4096 by default. |
| Ray tracing | Custom BVH | Custom BVH or Metal's acceleration structures and intersector. Switching recompiles the shaders and rebuilds the scene's trees (about a second the first time, then milliseconds). The images match to 58–72 dB PSNR, and every quality score in the benchmarks is within ±0.2 dB. |
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
* **Shared helpers.** Every type answers the same five questions in `Shaders.metal`:
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
* **Sample and target.** A sample is (light element, a point on it as two 16-bit coordinates). Points move with their light, so reusing a sample needs no Jacobian. The target function is the luminance of the sample's unshadowed diffuse plus specular light at the pixel.
* **`restirTemporalKernel`**: per pixel and chain, 8 candidates from the table plus the suns, resampled by the target; then last frame's reservoir at the reprojected pixel (depth and normal tests), merged with the generalized balance heuristic. That uses last frame's light positions, so moving lights stay unbiased. Confidence is capped at 8 frames.
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
| ReSTIR | 8.81 | 10.17 | 11.33 | 12.43 | **13.77** | **15.41** | **17.07** |

| Night market bulbs | 1024 | 4096 | 16384 |
|---|---|---|---|
| Grouped | 33.91 | 87.01 | — |
| ReSTIR | **18.36** | **18.82** | **19.31** |

From 32 to 16384 lights, ReSTIR's frame grows by 5.7 ms, while the light count grows 512×. It costs about 4.4 ms more than the grouped picker at 1 light (the extra passes and their denoiser) and breaks even near 256 lights.

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

* **Unbiased:** accumulated ReSTIR without reuse matches tracing every light in every light-type scene (rect, tube and sphere lights and their emissive-mesh twins, spots, tubes, area, emissive, mixed, the stress hall): mean brightness ratio 1.00, 39–65 dB (`METALRENDERER_BENCH=restircheck`). With reuse, it stays at 1.00 (table above).
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

* **Gallery close-up** (PBR, full detail): 32.4 dB, against 31.1 dB path traced and 30.7 dB with cascades.
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
| Local fog volumes | On | The scene's volumes: ground mist in the hall and the garage, haze over the stage, a glow around the orbs, dust in the sun scene's room. |
| Fog in reflections | On | One more shadow ray per reflection pixel. |

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
* **Updates:** `skyKernel` redraws a sixteenth of the texels each frame. It dispatches only those, so no SIMD lanes idle. A scene switch or settings change redraws them all.
* **Sun disc:** drawn per camera pixel, darkening toward its limb and dimmed by the clouds in front of it. GI rays never see it; next-event estimation delivers the sun.
* **Constant sky:** scenes with a constant sky skip all of this and render exactly as before.

**Atmosphere** (Hillaire 2020):
* **Model:** single scattering in an Earth-sized atmosphere (Rayleigh, Mie, ozone), marched in 20 steps per texel. It is lit through a transmittance table and has a multiple-scattering table; both are computed once.
* **Sun light:** `Atmosphere.swift` computes the transmittance toward the sun on the CPU, and the sun light's colour follows it. In Sun and sky, the day cycle now colours itself, as do the valley's mornings and evenings.
* **Exposure:** it is fixed, so the valley's sun stays at least 10° up; below that the sky is 20–50× darker than at noon.

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

### Geometry debug views

The View popup and key 9 cycle six views of what the primary rays hit. They run as a separate pass (about 2 ms at 1280×800) only while shown, so normal frames don't pay for them. Colours are shaded by the facing ratio so shapes stay readable.

| View | Shows |
|---|---|
| Triangles | A random colour per triangle, for all geometry. Virtual triangles keep their colour when the cut's BLAS is rebuilt. |
| Clusters | A random colour per virtual-geometry cluster (up to 128 triangles); other geometry is grey. |
| Groups | A random colour per cluster group, the unit the DAG simplifies and streams. |
| LOD level | The cluster's DAG level on a blue (finest) to red (coarse) scale: finer near the camera, coarser far away. |
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
CPU    animate objects + lights  ->  write instance transforms (triple-buffered)
       virtual geometry (background thread): Nanite cut per instance -> SAH BLAS over the cut where it changed
GPU 0  textures: map + upload the mip levels last frame's hits asked for (sparse textures), unmap unused ones
GPU 1  custom RT: rebuild the moving instances' top-level BVH (prep -> Morton keys -> sort -> hierarchy -> boxes)
       (Metal RT instead: refit the instance acceleration structure, rebuild it every 16 frames)
    1b lightMapKernel  per-light distance maps (radiance cascades, path tracer with light maps)
    2  traceKernel     primary ray -> G-buffer (normal, depth, albedo, emission, motion, world position)
                       direct (up to 4 lights): 1 shadow ray per light (+ per-light visibility and penumbra width)
                       indirect (path traced): cosine-sampled path, NEE at every bounce
                       (lighting is stored without albedo so the denoiser can blur it freely)
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
| `Renderer.swift` | Metal setup, per-frame encoding, input; Metal's acceleration structures when that tracer is selected |
| `BVH.swift` | The custom ray tracer's node format and CPU builder (binned SAH) for bottom-level and static top-level trees |
| `CustomRayTracer.swift` | The custom ray tracer's buffers, the per-frame GPU build of the moving objects' tree, its argument buffer |
| `Settings.swift` | Every user-adjustable setting, with defaults and ranges |
| `SettingsPanel.swift` | The Render Settings panel |
| `SettingsStore.swift` | Saves and restores the settings between launches |
| `EnvExport.swift` | Copy as Env: the `METALRENDERER_*` variables for the current settings |
| `GPUProfiler.swift` | The panel's GPU pass timings (timestamp counters at encoder boundaries) |
| `Upscaler.swift` | MetalFX temporal (or spatial) scaler and the sub-pixel jitter sequence |
| `TemporalUpscaler.swift` | The custom upscaler's history textures and dispatch (`taauKernel`) |
| `RadianceCascades.swift` | Radiance cascades: probe textures, radiance atlases, per-frame passes |
| `BlueNoise.swift` | Void-and-cluster blue-noise generator |
| `Benchmark.swift` | Benchmark mode (`METALRENDERER_BENCH`) |
| `Scene.swift` | The Cornell, stress and gallery scenes: meshes, materials, instances, animation paths; the light types, their poses and visible shapes, shadow-denoiser groups, emissive-mesh lights and the light table; glTF models and their lights |
| `Scene+Lights.swift` | The six light demo scenes, the Misty hall and the fog volumes, the Open valley, the Night market, and the light-check scene the `lightcheck` benchmark renders |
| `LightTable.swift` | Every light and emissive triangle as one alias table by power (ReSTIR DI's candidates; GI with many lights) |
| `FogNoise.swift` | The fog's tiling 3D density noise |
| `Atmosphere.swift` | The atmosphere's constants and sun transmittance on the CPU (the sun light's colour); HDR sky images, with their sun found and cut out |
| `GLTFLoader.swift` | glTF 2.0 (`.glb` / `.gltf`) parsing: accessors, node hierarchy, metallic-roughness materials, images, punctual lights |
| `MaterialTextures.swift` | Whole textures, decoded at a capped size (when streaming is off or unsupported) |
| `TextureStreamer.swift` | Texture streaming: mip-chain caches, sparse textures, feedback, mapping and uploads |
| `MeshClusterizer.swift` | Clusters (≤128 triangles) by region growing, and cluster groups |
| `MeshSimplifier.swift` | Quadric half-edge-collapse simplifier with locked borders and seam-aware attribute handling |
| `VirtualGeometryBuilder.swift` | The cluster LOD DAG, cluster pages and the cache file format |
| `VirtualBLAS.swift` | Virtual geometry at run time (default): the cut per instance and a background SAH BLAS over it |
| `VirtualGeometry.swift` | The GPU-driven variant (`METALRENDERER_VG_MODE=clusters`): GPU cut, page pool and streaming, cluster tree |
| `GPUTypes.swift` | Structs shared with the shaders. Their layout must match `Shaders.metal` |
| `Shaders.metal` | All GPU code |

## Notes for M1 / M2 Macs

M1 and M2 have no ray tracing hardware, so Metal's intersector is software too, and the ray budget is the main cost here. That is also why this project's own BVH traversal can beat it (see the stress test); on M3 and later, compare the two again with `METALRENDERER_BENCH=rt`:

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
  * What didn't help:
    * Skipping postponed subtrees that start beyond the closest hit (a second stack of entry distances) cost 15%: the extra stack traffic outweighs the boxes it skips.
    * A smaller stack (32 entries) changed nothing.
    * Bigger leaves (a higher SAH traversal cost) were 2–4% slower.
    * A watertight triangle test (Woop et al.) was 30% slower and changed no image. The upscaled moving frames that differ from Metal's along silhouettes come from depth and motion differing in the last float bits, which the upscaler's depth-edge and clip decisions amplify; native frames match bit for bit.
    * An SAH-built moving-object tree (`METALRENDERER_RT_BUILD=cpu`) traces only 4–7% faster than the GPU LBVH.
* MetalFX's built-in denoiser (`MTLFXTemporalDenoisedScaler`) also runs on an M1 Max under macOS 27, but it costs 4.2 ms at 640×400 → 1920×1200. That's more than this project's SVGF denoiser plus the temporal scaler it would replace (about 1.5 ms together). On M3 and later, with ray tracing hardware, it may be worth swapping passes 3, 4 and 6 for it.

* **glTF gallery** (11 Tripo models, 17.9M triangles, 67 textures of up to 4096², M1 Max, 640×400; `METALRENDERER_BENCH=gallery`, `Tools/eval/gallery.py`).
  * Virtual geometry against full-detail meshes, same scene and custom tracer (GPU ms per frame):

    | | Full detail | VG 1 px | VG 2 px |
    |---|---|---|---|
    | Triangles traced | 17.9M | 0.4M (overview), 1.1M (close-up) | 0.18M |
    | Geometry memory | ~1.5 GB (BLAS + vertex buffers) | 40 MB (overview), 108 MB (close-up) | 18 MB |
    | Overview, direct light | 4.33 | 4.09 | 3.81 |
    | Camera fly-through (3× upscaled) | 16.63 | 17.54 | — |

    About the same speed, at 3–4% of the memory. The cut updates in the background in 30–150 ms when it changes (the fly-through rebuilt 900 instance BLASes). Quality: the cut is crack-free and looks the same. Against path-traced references it scores 29.7 dB at 1 px, 31.5 dB at 0.5 px and 35.0 dB at full detail on the overview; the single sample per pixel makes texture detail alias, so sub-pixel geometry changes cost dB there (blurred 4×4, VG 1 px and full detail agree to 41 dB).
  * PBR against the path-traced references (close-up, full detail): 30.7 dB with cascades, 31.1 dB path traced. Average colour per region matches within 0.5% on the glossy floor, 1–3% on the steel plinths, about 5% on the bronze owl. The reflection pass costs 0.4 ms on a still frame and 0.6–1.0 ms in motion.
  * Texture streaming: 14 MB resident from the overview and 46–65 MB close up, against 2.6 GB for all levels (or 711 MB capped at 2048). Images match fully resident 4K textures at 56–77 dB. Uploads are capped at 48 MB per frame.
  * What mattered:
    * **One SAH tree per model over the cut, not a tree of clusters.** The first runtime selected the cut on the GPU, streamed cluster groups into a 768 MB pool (buddy allocator, LRU, Nanite's residency rules) and built a per-frame LBVH over the selected clusters, each with its own little BVH. It works (`METALRENDERER_VG_MODE=clusters`) but traces 2× slower than full detail. Rays visit 8.6 nodes per ray inside models instead of 3.8, because cluster boxes overlap. Splitting the tree per instance to drop the per-cluster transform changed nothing, and an offline SAH over the same clusters would only save 15%.
    * **Simplification that keeps going:** locking only group borders (not the mesh's own open edges), letting seam and border vertices slide along their seams, a relaxed pass across UV seams for fragmented Tripo atlases when the strict one gets stuck, passing stuck groups up a level, and filling clusters spatially. That took the DAG from 883 root groups per model (full-detail fragments, always drawn) to one 366-triangle root, and the cut from 62k clusters to 3.9k.
    * **Texture levels from the largest UV stretch** (as GPUs do) and a histogram instead of a minimum: UV slivers and close self-reflections had asked for 4K mips of models 100 px tall (600 MB resident instead of 14).
  * In close-ups, Metal's intersector on the full-detail meshes is about 12% faster than this tracer with virtual geometry (11.1 vs 13.7 ms); from the overview, and in the stress scene, the custom tracer is faster.

## Where to go next

1. **Thin-feature locks for the custom upscaler:** in busy scenes it flickers 3× as much as MetalFX on still frames (see the stress test). Marking pixels where a thin, high-contrast feature keeps appearing and protecting their history from the clip, as FSR 2 does, would fix that.
2. **Many lights, sharper:** ReSTIR scales flat but stays below the grouped picker's quality up to 1024 lights, because SVGF blurs noisy radiance where the shadow denoiser only blurs visibility. Candidates from a world-space grid of light lists (ReGIR) instead of power alone would raise the quality per ray in a large street, and a denoiser built for ReSTIR (ReBLUR or ReLAX-style, with the reservoirs' confidence as input) would blur less. With the grouped picker, still frames still flicker more than with one ray per light; a denoiser that tracks the variance of fractional visibility over time is the likelier fix there.
3. **Faster custom traversal:**
   * Collapse the binary trees into 4-wide nodes, so a ray tests four boxes per fetch and pushes less. The GPU LBVH would need a collapse pass too, or the single loop would diverge again.
   * Give the LBVH SAH-quality top levels, for example with treelet restructuring or PLOC: a CPU SAH tree traces 4–7% faster.
   * With 2000 objects the frame still costs 1.4 ms more than with 400; sorting secondary rays by direction for coherence is the other thing to try.
4. **Better GI caching:** radiance cascades and ReSTIR GI's multi-bounce feedback fall back to the scene's average indirect light at points no screen pixel covers, and cascades lose 7 dB to the path tracer in cluttered scenes like the stress hall. A coarse world-space irradiance volume (or DDGI probes) would give those points real local values.
5. **Cheaper ReSTIR GI:** its paths cost what the path tracer's do, so it runs at 2–3× the cascades' cost. Half-resolution reservoirs (with full-resolution reuse), or paths that end in a world-space radiance cache after one bounce, would cut that. The multi-bounce feedback alone, which made most of its gain, could also be given to the plain path tracer. And a denoiser that uses the reservoirs' confidence (ReBLUR or ReLAX-style) might turn reuse's lower raw noise into a lower error, which SVGF doesn't.
6. **Deforming meshes:** update vertices in a compute pass, then refit that mesh's bottom-level tree with a bottom-up box pass like `rtFitKernel` (or call `refit` on its BLAS with the Metal tracer).
7. **Specular, better:** reflections reproject with surface motion, so glossy reflections smear a little in camera moves (virtual-point reprojection would fix that), and secondary hits treat specular as diffuse.
8. **Virtual geometry:** a GPU-built (or treelet-optimized) BLAS over the cut would let the cut update every frame; LOD cross-fades would hide the rare pop; the Metal tracer could build BLASes over the cut too.
9. **Texture compression:** ASTC or BC7 would cut the texture cache (2.5 GB) and streaming bandwidth by 4×.
10. **Rasterized G-buffer:** generate primary visibility with a raster pass to save one ray per pixel.
11. **Custom upscaler at 2× and 1.5×:** it matches MetalFX in motion at 3× but trails by up to 0.7 dB in camera moves at lower factors. Tuning per factor (its motion cuts are scaled by the factor today), or a per-pixel disocclusion test that doesn't misfire on jittered edges, would be the next step.
