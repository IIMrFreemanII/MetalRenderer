# MetalGI

A minimal real-time ray tracer for macOS and Metal, with dynamic lights and global illumination.
It's built for Apple Silicon and tuned for an M1 Max.

* **Dynamic scenes:** objects and lights move every frame. Pick a scene in the settings panel:
  * a small Cornell-style room;
  * a **stress test** hall with up to 2000 moving objects and 256 moving lights (see below);
  * the glTF **Gallery**;
  * six light demos (see "Light types" below).
* **Light types:** sphere (point) lights, **spot** lights, a **sun** with a sky colour, **rect** area lights and **tube** lights.
  * Every type has soft ray-traced shadows, GGX highlights, the shadow denoiser and every GI method.
  * The scene's shaders are specialised for the light types it uses, so a scene with only sphere lights runs the same code as before.
* **Emissive meshes are lights:** any glowing surface (a neon sign, a screen, a glTF emissive texture) is sampled for direct light with shadow rays, one triangle at a time.
* **glTF lights:** `KHR_lights_punctual` point, spot and directional lights load with their models.
* **Custom ray tracing (default):** the shaders traverse this project's own two-level BVH instead of Metal's acceleration structures.
  * Each mesh gets a bottom-level tree (binned SAH, built once on the CPU).
  * Objects that never move get a top-level tree of their own, also built once.
  * Moving objects and light spheres get a top-level tree rebuilt from scratch on the GPU every frame as an LBVH: Morton codes, a bitonic sort, the Karras hierarchy and a bottom-up box pass. This takes 0.08–0.12 ms for 400–2000 objects.
  * Rays walk both levels in a single loop.
  * On an M1 Max, which has no ray-tracing hardware, this is 19–24% faster per frame than Metal's intersector in the stress test, and on par in the Cornell room (see below).
  * Metal's acceleration structures stay one click away in the settings panel ("Ray tracing"), and so does `METALGI_RT=metal`.
* **glTF models:** `.glb` and `.gltf` files load with their node hierarchy and metallic-roughness materials.
  * The **Gallery** scene shows every model in `Assets/` on plinths, two of them on turntables, under 8 moving lights.
  * File > Open… (⌘O) or dropping files on the window adds models to any scene.
  * Textures supported: base colour, metallic-roughness, normal and emissive (normal maps use tangents derived per triangle from the UVs).
  * Scenes load in the background while the old one keeps rendering.
* **Virtual geometry (Nanite-style, default with the custom tracer):** meshes of 65k+ triangles become level-of-detail DAGs of 128-triangle clusters.
  * Everything is this project's own code: clustering, quadric simplification with locked group borders, seam- and border-aware collapses, and the DAG.
  * Each model is built once (about 7 s per 2M triangles) and cached in `Assets/.metalgi-cache/`.
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
* **Direct light:** ray-traced soft shadows. With up to 4 lights, each light gets one shadow ray per pixel. With more, lights are split into 4 colour groups, and each pixel picks one light per group, weighted by how much light it would get from it unshadowed, then traces one shadow ray to it. The cost is then 4 rays per pixel whatever the light count.
* **Global illumination, three methods** (switch with **M** or in the settings panel):
  * **Radiance cascades (default):** probes on a screen grid trace world-space rays over distance intervals that grow 4× per cascade. The cascades are merged top-down, giving each probe its incoming light without noise.
  * **Surfels:** a pool of small disks on visible surfaces, after EA SEED's GIBS. Each disk traces 16 rays per frame and accumulates irradiance over time. Pixels average the disks around them.
  * **Path traced:** a 1-sample-per-pixel diffuse path is traced for 1 to 8 bounces. Each bounce samples one light directly (next-event estimation), picked in proportion to its unshadowed light there, and picks up sky light. The result is denoised.
  * Surfels and radiance cascades get **multi-bounce** light, and light their ray hits from per-light **light-visibility maps**, so they need no shadow rays.
* **Light-visibility maps:** each frame, every light traces a 128×128 map of the distance to the nearest geometry in each direction (smaller beyond 16 lights, so all the maps together always cost about as much as 16). The sun's map is orthographic instead, over the scene's bounding sphere. Secondary hits look up their shadowing there: from every light with up to 8 lights, otherwise from 4 lights picked by their unshadowed light. The path tracer can also use these maps for its bounces ("light bounces from light maps").
* **Upscaling (optional):** the frame is traced at low resolution with sub-pixel jitter, and a temporal upscaler rebuilds a sharper, anti-aliased image at up to 3× the resolution. It's on by default at 3×. Press **U** to cycle through off, 1.5×, 2× and 3×. The settings panel picks the upscaler:
  * **Custom (TAAU)** (default): this project's own pass (`taauKernel`). It is about 0.5 ms cheaper per frame than MetalFX, much sharper and steadier on still images, and as good in motion at 3× (see below).
  * **MetalFX temporal**.
  * **MetalFX spatial**: cheaper still, but it doesn't anti-alias edges.
* **Blue-noise sampling (on by default, B):** random numbers come from a 128×128 void-and-cluster blue-noise tile, shifted every frame by the golden ratio or the R2 sequence. Its stratified shadow samples steady the shadow denoiser's history clamp.
* **Shadow denoiser (direct light):** per light, direct light is an exact unshadowed term times the visibility of one random point on the light. Only that visibility is noisy, so only it is filtered (one light per channel; with more than 4 lights, one light group per channel), and the composite pass multiplies it back onto the exact unshadowed light. Shading is never blurred. The temporal pass clamps the reprojected history to what the current frame's neighbourhood allows, so moving shadows don't lag. Then up to 3 edge-aware 3×3 passes blur no wider than each light's penumbra, estimated from occluder distances, and skip 8×8 tiles that are fully lit or fully shadowed. This follows AMD FidelityFX's shadow denoiser and NVIDIA's SIGMA.
* **SVGF denoiser (indirect light):** temporal accumulation (16 frames) with motion vectors and disocclusion checks, then a 4-pass edge-aware à-trous wavelet filter guided by variance. It filters path-traced indirect light (or surfel / cascade light if you enable that). With the shadow denoiser off, it also filters direct light as before. The settings were tuned against converged reference images (see below).
* **Settings panel:** a floating **Render Settings** panel (Tab or ⌘,) has a control for every setting, including the GI method and its parameters and the denoiser parameters. It shows the resolution, frame rate and GPU time.
* **Everything runs in compute kernels.** `Shaders.metal` is compiled at runtime, so you can edit it while the app runs and press **R** to reload.

## Build and run

You need Xcode 15 or newer and macOS 13 or newer.

```bash
cd MetalGI
swift run -c release
```

You can also open `Package.swift` in Xcode, choose **My Mac**, and press Run. Use the Release scheme for real frame rates.

> The app finds `Shaders.metal` through its source path, so run it from this folder rather than copying the binary somewhere else.

### Benchmark mode

```bash
METALGI_BENCH=1 swift run -c release
```

This runs a fixed animation through a list of settings (GI bounces, denoiser, render scale, MetalFX upscaling), times each GPU pass, prints a table, and quits. Set `METALGI_BENCH_DIR=<folder>` to also save one PNG per setting. Use `METALGI_BENCH=quality` to render the same frames natively and with MetalFX instead, so you can compare the PNGs. Use `METALGI_BENCH=noise` to render white- and blue-noise sampling next to converged reference images, made by averaging thousands of frames of the paused scene. Use `METALGI_BENCH=denoise` to render a few frames for scoring denoiser changes against those references. Set `METALGI_DENOISE`, for example `passes=3,tpasses=2,sigma=2,history=16,antilag=1,separate=1`, to override the denoiser in every setting without rebuilding (`tpasses` is the pass count with surfel or cascade GI).

Each pass runs in its own command buffer so it can be timed, which serializes the whole frame. Set `METALGI_BENCH_SPLIT=0` to encode frames exactly as the app does (one command buffer, with radiance cascades overlapping the denoiser) and report only whole-frame GPU time. `METALGI_OVERLAP=0` turns that overlap off, for A/B timing.

Use `METALGI_BENCH=shadow` to score direct-light denoising (static, moving and camera-move frames against a converged reference). Use `METALGI_BENCH=upscale` to score the upscalers against supersampled native 1920×1200 references, on the albedo view and on direct light. `METALGI_UPSCALERS=metalfx,custom,spatial` picks the upscalers, and `METALGI_GI=upscaler=metalfx` switches every setting to one (`scale=0.75,factor=2` tests another upscale factor against the same references). Its "pan" frames fly the camera over the frozen scene; `METALGI_PAN=rotate` makes that a pure rotation. `METALGI_DENOISE` also takes `shadows=0` (SVGF for direct light), `spasses`, `shistory`, `sclamp` and `ssigma`. `METALGI_GI` takes `blue` and the custom upscaler's `taau…` keys (see `Benchmark.swift`).

Use `METALGI_BENCH=stress` to time the stress scene against light count (1 to 256), object count (0 to 2000) and GI method, and `METALGI_BENCH=stressq` to score its direct light at 32 and 128 lights, and its final image, against converged references. `METALGI_SCENE=stress,objects=400,lights=32` loads the stress scene in every setting of any mode. `METALGI_LIGHTS=all` traces one shadow ray per light again (the brute-force baseline), `METALGI_GI=lightrays=2` sets the shadow rays per light group, and `METALGI_TLAS=<frames>` sets the rebuild interval of Metal's TLAS (1 = every frame; the custom tracer rebuilds its own every frame). `METALGI_BENCH_ONLY="32 lights|camera"` runs only the settings whose names contain one of these strings.

`METALGI_RT=metal|custom` picks the ray tracer for every setting. Use `METALGI_BENCH=rt` to compare the two:
* It first renders paused frames in every GI mode on both scenes with the `METALGI_RT` tracer. Run it once per tracer and diff the PNGs with `Tools/eval/pngdiff.py`.
* Then it times moving frames at 0–2000 objects, alternating the two tracers.

`METALGI_RT_BUILD=cpu` builds the custom tracer's moving-object tree on the CPU with binned SAH instead of on the GPU (a better tree, for comparison). `METALGI_RT_CHECK=1` checks every mesh's tree against brute-force ray/triangle tests at startup. `METALGI_RT_STATS=1` compiles traversal counters in, and benchmarks print them per setting: nodes, instance and cluster entries, and triangle tests per ray.

Use `METALGI_BENCH=gallery` for the glTF gallery. It renders path-traced references (full BRDF, full-detail meshes, 4 bounces; skip them with `METALGI_GI_REFS=0`), then the overview and a close-up with full-detail meshes and with virtual geometry at 0.5, 1 and 2 px, alternating so heat affects them alike, and the camera fly-through. Score it with `Tools/eval/gallery.py`.

These variables apply to the gallery and to models in general:
* `METALGI_SCENE=gallery` starts the app in the gallery; `model=<path>` adds a model, as File > Open does.
* `METALGI_GALLERY="owl|demon"` loads only the matching files; `METALGI_ASSETS=<folder>` uses another folder.
* Virtual geometry:
  * `METALGI_VG=0` turns it off; `METALGI_VG_TAU=<px>` sets the allowed error.
  * `METALGI_VG_MODE=clusters` uses the GPU-driven cluster variant (see below), with `METALGI_VG_POOL=<MB>` for its page pool.
  * `METALGI_VG_SYNC=0|1` forces background or synchronous cut updates; benchmarks run them synchronously.
  * `METALGI_VG_TEST=<model.glb>` builds a model's DAG, checks its invariants, round-trips the cache file and exits.
  * `METALGI_BENCH=vgdebug` renders every geometry debug view at the gallery overview and close-up, with virtual geometry and (for triangles, triangle size and cost) full-detail meshes; set `METALGI_BENCH_DIR` for the PNGs.
* Textures:
  * `METALGI_TEXTURE_STREAMING=0` loads every texture whole, capped at `METALGI_TEXTURE_SIZE` (default 2048).
  * `METALGI_TEXTURE_BUDGET=<MB>` sets the streaming heap.
  * `METALGI_TEXTURE_DEBUG=1` prints each texture's wanted and resident level.
* `METALGI_SPECULAR=0` turns specular off.

For the lights:
* `METALGI_SCENE=spots|sun|area|tubes|emissive|mixed` starts in a light demo scene.
* `emissivelights=0`, added to `METALGI_SCENE` or set as `METALGI_EMISSIVE_LIGHTS=0`, turns emissive-mesh lights off.
* `METALGI_SCENE=check=empty,model=Tools/test-assets/punctual-lights.gltf` shows the glTF light test file (a point, a spot and a sun) on an empty floor.
* `METALGI_BENCH=lights` renders each demo scene paused at t = 5 s: direct light only, then each GI method, then moving. `METALGI_LIGHTS_SCENES="sun|mixed"` picks scenes.
* `METALGI_BENCH=lightcheck` cross-checks the closed-form area lights. A rect, a tube and a sphere light are each rendered over a floor next to an emissive-mesh twin of the same shape and radiance, converged over 1024 frames. The mesh estimator is unbiased, so the pairs should match:
  * the sphere matches its twin within 0.1%;
  * the rect within 1%;
  * the tube within 7%, which is the extra light from the capsule twin's end caps.

The models in `Assets/` aren't part of the repository (they're 596 MB); put any glTF files there. The caches in `Assets/.metalgi-cache/` (4.4 GB for the 11 sample models: 1.9 GB of geometry DAGs, 2.5 GB of texture mip chains) can be deleted at any time; they're rebuilt on the next load.

Use `METALGI_BENCH=gi` to compare the GI methods. It first renders 8-bounce, unclamped path-traced references by averaging thousands of frames of the paused scene; skip them with `METALGI_GI_REFS=0` once you have them. Then, for each method, it renders a static frame, the next one (for flicker), an indirect-only frame, a moving frame, a frame at the end of a scripted camera move, and a frame with MetalFX on. `METALGI_GI_MODES` picks the methods, for example `pt,pt-lightmaps,surfels,cascades,cascades-hq`. `METALGI_GI` overrides GI settings everywhere, for example `mode=surfels,rays=8` or `mode=cascades,spacing=4,b1=0.25`. `METALGI_TG`, for example `trace=16x8`, overrides a kernel's threadgroup size.

`Tools/eval/` scores the saved PNGs against reference images committed in `Tools/eval/refs/` (PSNR and flicker; see its README).

The benchmark renders frames back to back without vsync, so the GPU's clock stays steady. Long runs can still throttle as the GPU heats up, so compare timings from short runs. The lists of settings are in `Benchmark.swift`.

## Controls

| Key | Action |
|---|---|
| Drag mouse | Look around |
| W A S D, Q E | Move, down/up (hold Shift to move faster) |
| Space | Pause animation |
| G | Toggle global illumination |
| M | GI method: path traced, surfels, radiance cascades |
| N | Toggle denoiser (shows the raw 1-spp signal) |
| [ ] | Fewer / more GI bounces (path traced) |
| - = | Lower / raise render resolution |
| U | MetalFX upscaling: off, 1.5×, 2×, 3× (output is capped at the window's pixel size) |
| B | Toggle blue-noise sampling (on by default; the tile is generated at startup, which takes about 0.5 s) |
| 1–8 | View: final, raw direct, raw indirect, normals, albedo, history length, indirect only, GI debug (surfels: one color per surfel, holes in red; cascades: probe grid over interpolation confidence) |
| 9, 0 | Cycle the geometry debug views (see below); back to the final image |
| L | Freeze LOD: virtual geometry keeps choosing detail for where the camera is now |
| R | Hot-reload `Shaders.metal` |
| ⌘O, drop files | Add glTF models (`.glb` / `.gltf`) in front of the camera |
| Tab, ⌘, | Show or hide the Render Settings panel |

The window title and the settings panel show the resolution, frame rate and GPU time. The panel never takes keyboard focus, so the keys above keep working while it's open, and changes you make with the keys show up in it.

### Scene settings

| Setting | Default | Effect |
|---|---|---|
| Scene | Cornell room | Cornell room (5 objects, 2 moving, 3 lights), the stress test, the Gallery of glTF models in `Assets/`, or one of the light demos (see below). Switching rebuilds the geometry and acceleration structures in the background, and picks that scene's GI defaults: radiance cascades for the Cornell room, surfels (8 rays, 64k pool) for the others. Reset to Defaults also uses the current scene's. The gallery's first load builds its geometry and texture caches (about a minute for 11 models); later loads take seconds. |
| Objects | 400 | Stress test: objects in the hall, about 85% of them moving. Applied when you release the slider. |
| Lights | 32 | Stress test: moving sphere lights, 1 to 256. Their total power stays the same, so the brightness barely changes. |
| Ray tracing | Custom BVH | Custom BVH or Metal's acceleration structures and intersector. Switching recompiles the shaders and rebuilds the scene's trees (about a second the first time, then milliseconds). The images match to 58–72 dB PSNR, and every quality score in the benchmarks is within ±0.2 dB. |
| Virtual geometry | On | Custom ray tracer only: big glTF meshes as streamed level-of-detail cuts. Off: full-detail meshes. |
| Geometry error | 1 px | The cut's allowed geometric error in traced pixels. 0.5 px: about 2× the triangles, closer to full detail; 2 px: half. Changes apply within a few frames. |
| Freeze LOD | Off | Keeps the cut chosen for the camera position at the moment it was turned on (title: "LOD frozen"). Fly up to a model to see the coarse geometry it gets from far away; turn it off and it refines within a few frames. |
| Specular | On | GGX specular for glTF materials (direct and reflections). Off: diffuse only, and no reflection pass. |
| Emissive surfaces are lights | On | Emissive geometry is sampled for direct light, with shadow rays, and lights GI through its light map. Off: it only lights what GI rays happen to hit, as before (surfels and radiance cascades ignore it entirely). Toggling it rebuilds the scene. |
| Shadow rays | 1 per group + reuse | With more than 4 lights: shadow rays per light group and pixel. "Reuse" keeps each pixel's light picks for up to 4 frames (ReSTIR-style temporal resampling): a third less flicker on still frames for about 0.7 ms. 2 rays per group halve the flicker and are the most accurate, for about 4 ms more at 400 objects. |

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

Costs at 960×600 with surfel GI on an M1 Max:

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

With the Metal tracer, the clusters, groups and LOD views are grey, because Metal traces full-detail meshes. The views work in both virtual-geometry runtimes. In `METALGI_VG_MODE=clusters`, cluster colours follow a cluster's place in the page pool, so they change when it is streamed again.

### Denoiser settings

| Setting | Default | Effect |
|---|---|---|
| Shadow denoiser | on | Filters each light's (or light group's) visibility instead of the lit colour (see above). With it off, SVGF filters direct light. |
| Shadow passes | 3 | Edge-aware 3×3 passes over the visibility (steps 1, 2, 4). |
| Separate direct / indirect | on | Filters the two separately. Indirect noise then no longer widens the filter across direct-light shadow edges. It doubles the denoiser's cost (about +0.45 ms at 640×400). |
| Filter passes | 4 (2 with surfels or cascades) | SVGF à-trous passes (1–5). Fewer passes give sharper contact shadows and more noise. With surfel or cascade GI and the shadow denoiser off, only direct light goes through SVGF, and 2 passes measured the same as 4. The slider sets the count for the selected GI method. |
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
    1b lightMapKernel  per-light distance maps (surfels, radiance cascades, path tracer with light maps)
    2  traceKernel     primary ray -> G-buffer (normal, depth, albedo, emission, motion, world position)
                       direct (up to 4 lights): 1 shadow ray per light (+ per-light visibility and penumbra width)
                       indirect (path traced): cosine-sampled path, NEE at every bounce
                       (lighting is stored without albedo so the denoiser can blur it freely)
    2c manyLightsKernel more than 4 lights: per light group, pick 1 light by unshadowed light, 1 shadow ray
                       (+ per-group visibility and penumbra width); manyLightsReuseKernel also resamples
                       against last frame's picks (default)
    2e meshLightsKernel emissive meshes: 1 light by its proxy, 1 triangle by emitted power, 1 shadow ray
                       (denoised by SVGF on its own, or added to the direct light without the shadow denoiser)
    2b surfels         transform -> grid (count, scan, scatter) -> trace -> gather + spawn -> lifecycle
       or cascades     probes -> trace + merge per cascade (top down) -> SH projection -> resolve
    2d reflectionKernel glTF specular materials: 1 GGX ray per pixel, hit lit by 1 light sample + this frame's
                       diffuse GI on screen; / specular albedo; temporal + 2 a-trous passes
    3  shadowTemporalKernel  direct light: reproject + clamp per-light visibility, penumbra widths, tile classes
       shadowFilterKernel x3 edge-aware, penumbra-limited 3x3 passes (skips fully lit / shadowed tiles)
    3b temporalKernel  SVGF for indirect light: reproject last frame, reject disocclusions, blend, track variance
                       (surfel / cascade indirect light skips the denoiser unless you enable it)
    4  atrousKernel x4 edge-aware wavelet filter (step 1, 2, 4, 8)
    5  compositeKernel exact unshadowed light (diffuse + GGX) x visibility + indirect, x albedo, + reflections x
                       specular albedo + emission -> ACES tonemap
                       -> drawable (sRGB format: the GPU encodes), or with upscaling linear colour at render resolution
    6  upscale         taauKernel straight into the drawable, or MetalFX into a private texture + a copy
```

With radiance cascades, 2b and 3–4 don't depend on each other. The frame then uses one concurrent compute encoder and runs them in lock step, with a barrier after each step: light map + trace + probes, then temporal + the top cascade, each à-trous pass + the next cascade down, and so on. Small dispatches on M1 leave the GPU partly idle, so this overlap saves about 0.2 ms. The other GI methods run in order.

| File | What it holds |
|---|---|
| `Renderer.swift` | Metal setup, per-frame encoding, input; Metal's acceleration structures when that tracer is selected |
| `BVH.swift` | The custom ray tracer's node format and CPU builder (binned SAH) for bottom-level and static top-level trees |
| `CustomRayTracer.swift` | The custom ray tracer's buffers, the per-frame GPU build of the moving objects' tree, its argument buffer |
| `Settings.swift` | Every user-adjustable setting, with defaults and ranges |
| `SettingsPanel.swift` | The Render Settings panel |
| `Upscaler.swift` | MetalFX temporal (or spatial) scaler and the sub-pixel jitter sequence |
| `TemporalUpscaler.swift` | The custom upscaler's history textures and dispatch (`taauKernel`) |
| `SurfelGI.swift` | Surfel GI: surfel pool, spatial grid, per-frame passes |
| `RadianceCascades.swift` | Radiance cascades: probe textures, radiance atlases, per-frame passes |
| `BlueNoise.swift` | Void-and-cluster blue-noise generator |
| `Benchmark.swift` | Benchmark mode (`METALGI_BENCH`) |
| `Scene.swift` | The Cornell, stress and gallery scenes: meshes, materials, instances, animation paths; the light types, their poses and visible shapes, shadow-denoiser groups and emissive-mesh lights; glTF models and their lights |
| `Scene+Lights.swift` | The six light demo scenes, and the light-check scene the `lightcheck` benchmark renders |
| `GLTFLoader.swift` | glTF 2.0 (`.glb` / `.gltf`) parsing: accessors, node hierarchy, metallic-roughness materials, images, punctual lights |
| `MaterialTextures.swift` | Whole textures, decoded at a capped size (when streaming is off or unsupported) |
| `TextureStreamer.swift` | Texture streaming: mip-chain caches, sparse textures, feedback, mapping and uploads |
| `MeshClusterizer.swift` | Clusters (≤128 triangles) by region growing, and cluster groups |
| `MeshSimplifier.swift` | Quadric half-edge-collapse simplifier with locked borders and seam-aware attribute handling |
| `VirtualGeometryBuilder.swift` | The cluster LOD DAG, cluster pages and the cache file format |
| `VirtualBLAS.swift` | Virtual geometry at run time (default): the cut per instance and a background SAH BLAS over it |
| `VirtualGeometry.swift` | The GPU-driven variant (`METALGI_VG_MODE=clusters`): GPU cut, page pool and streaming, cluster tree |
| `GPUTypes.swift` | Structs shared with the shaders. Their layout must match `Shaders.metal` |
| `Shaders.metal` | All GPU code |

## Notes for M1 / M2 Macs

M1 and M2 have no ray tracing hardware, so Metal's intersector is software too, and the ray budget is the main cost here. That is also why this project's own BVH traversal can beat it (see the stress test); on M3 and later, compare the two again with `METALGI_BENCH=rt`:

* By default the frame is traced at 0.5× the window size in points and upscaled 3× (1280×800 points → 640×400 traced → 1920×1200). Press `-` or `=` to change the traced resolution, and **U** to change the upscale factor.
* MetalFX temporal upscaling works on M1. With path-traced GI, the default resolution setting costs about 6.0 ms of GPU time on an M1 Max (custom upscaler), against 43 ms for a native 1920×1200 frame and 11.5 ms for a 960×600 frame stretched to the window. The stretched frame matches or loses to the upscaled one on image quality. If the GPU doesn't support MetalFX, the app renders at 0.75× without upscaling.
* With radiance-cascade GI (the default), the default frame costs about 2.4–2.8 ms with the custom upscaler (2.5 ms while the camera moves), against 3.0–3.1 ms with MetalFX. Only direct light goes through a denoiser in this mode.
* **Where the default frame's time goes** (M1 Max, per pass, serialized): upscaler 0.6 ms (0.7 while the camera moves; MetalFX takes 0.7–1.3 ms plus a 0.04 ms copy), trace 0.71, radiance cascades 0.61 (probes 0.07, trace 0.43, SH 0.01, resolve 0.11), shadow denoiser 0.25 (temporal 0.17, 3 filter passes 0.08), light map 0.10, composite 0.05, TLAS refit 0.04.
* **Shadow denoiser vs SVGF on direct light** (640×400, PSNR against a 4096-frame reference, `METALGI_BENCH=shadow`):

  | | Static | Contact crop | Flicker | Moving | Camera move | GPU ms |
  |---|---|---|---|---|---|---|
  | SVGF (16-frame history) | 47.5 dB | 42.6 dB | 0.15 | 30.2 dB | 30.0 dB | 0.32 (RC mode) / 1.07 (4 passes) |
  | Shadow denoiser | **48.9 dB** | **43.0 dB** | 0.15 | **43.9 dB** | **43.1 dB** | **0.25** |

  SVGF's long history smears moving shadows, because motion vectors move surfaces, not shadows. The shadow denoiser's clamp fixes that, and filtering visibility rather than colour keeps the shading sharp.
* **Upscalers** (PSNR against supersampled native 1920×1200 frames, `METALGI_BENCH=upscale`; "pan" = camera move over the frozen scene):

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
* **Comparing the GI methods** on an M1 Max, at the default setting (640×400 traced → MetalFX 3× → 1920×1200). PSNR is measured against the 8-bounce path-traced references (higher is better); GPU times are whole frames (`METALGI_BENCH_SPLIT=0`) from short benchmark runs.

  | GI method | GPU ms | Static | Contact crop | Indirect only | Moving | Camera move | Flicker |
  |---|---|---|---|---|---|---|---|
  | Path traced, 2 bounces | 6.4 | 25.7 dB | 24.4 dB | 21.1 dB | 25.6 dB | 25.5 dB | 0.30 |
  | Path traced + light maps | 5.0 | 25.6 dB | 24.3 dB | 21.1 dB | 25.6 dB | 25.5 dB | 0.31 |
  | Surfels | 3.4 | **36.7 dB** | **39.8 dB** | **33.9 dB** | 36.4 dB | **36.7 dB** | 0.20 |
  | Radiance cascades | **3.0** | 36.1 dB | 34.7 dB | 31.1 dB | 36.1 dB | 36.1 dB | **0.05** |
  | Radiance cascades, 4 px probes | 3.7 | 36.6 dB | 34.8 dB | 31.5 dB | **36.6 dB** | 36.6 dB | 0.05 |

  The path tracer's large error is mostly missing energy: in this white room, light keeps bouncing well past 2 bounces. Its image reaches only about 88% of the reference's brightness, while surfels and radiance cascades get multi-bounce light almost for free.
  * **Surfels** are the most accurate on static scenes and in contact areas.
  * **Radiance cascades** have no temporal accumulation, so they follow moving lights best and barely flicker. Their probes are interpolated across edges, though, which can show as thin light or dark streaks along object edges.
  * All quality columns are measured on 640×400 frames without MetalFX.
* **Stress test** (M1 Max, radiance cascades and the custom upscaler 3× from 640×400 unless noted; whole-frame GPU ms, best of two `METALGI_BENCH=stress` runs with `METALGI_BENCH_SPLIT=0`). "Before" is one shadow ray per light with the TLAS rebuilt every 256 frames; the next row adds the 16-frame rebuild; "now" adds light sampling with reuse and the lighter spheres. All of these were measured with Metal's acceleration structures, before the custom ray tracer, which takes 1.9–3 ms off the busier rows (see "Custom ray tracing vs Metal's" below):

  | 400 objects | 1 light | 4 | 8 | 16 | 32 | 64 | 128 | 256 |
  |---|---|---|---|---|---|---|---|---|
  | Before | 5.3 | 7.6 | 10.1 | 17.3 | 33.3 | 49.0 | 90.4 | 190.1 |
  | + TLAS rebuild every 16 frames | 3.6 | 5.8 | 8.0 | 12.7 | 21.9 | 42.3 | 83.5 | 167.7 |
  | **Now** | **3.5** | **5.5** | **6.3** | **7.3** | **8.1** | **8.9** | **9.9** | **11.7** |

  | 32 lights | 0 objects | 100 | 400 | 1000 | 2000 | Path traced (400) | Surfels (400) | Scene default: surfels, 8 rays (400) |
  |---|---|---|---|---|---|---|---|---|
  | Before | 6.6 | 19.4 | 33.3 | 29.3 | 30.9 | 50.3 | 30.2 | — |
  | **Now** | **3.3** | **5.2** | **8.1** | **11.1** | **12.6** | **16.3** | **12.2** | **10.1** |

  * **The TLAS was degrading.** A refit keeps the tree built for where the objects were, and with 400 objects moving freely, rays got 35% slower over 256 frames of refits. Rebuilding every 16 frames traces as fast as rebuilding every frame, for the refit's median cost.
  * **Shadow rays no longer grow with the light count.** Choosing each pixel's lights still weighs every light, but that's arithmetic, not rays. It runs in its own kernel (`manyLightsKernel`): inside `traceKernel`, whose register use limits occupancy, the same loop cost 4× as much. The remaining growth from 8 to 256 lights is that loop (about 2 ms), the composite's loop over all lights (0.8 ms at 256) and the light maps.
  * **Merging static objects into one acceleration structure didn't help.** Baking every unmoving object into one mesh (one instance instead of one each) made rays about 25% slower: walls and pillars lose their tight, flat instance boxes, which the top-level tree culls cheaply, and their big triangles split badly inside one tree. Merging only the small static clutter was within noise (−0.5 to +0.2 ms over 400–2000 objects), so it isn't used. What did help: the stress scene's small spheres use 320 triangles instead of 1280, which traces 5–6% faster and looks the same at their size.
  * **Quality** (direct light only, 640×400, PSNR against references that trace every light for 1024 frames, `METALGI_BENCH=stressq`, scored by `Tools/eval/stress.py`):

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
    | Radiance cascades | **8.1** | 25.5 dB | 28.0 dB | 0.79 | 25.3 dB | 25.3 dB |
    | Radiance cascades, 4 px probes | — | 27.4 dB | 29.9 dB | 0.69 | 27.1 dB | 27.1 dB |
    | Surfels, 16 rays, 32k pool | 12.2 | **35.6 dB** | **39.3 dB** | **0.46** | **36.0 dB** | 34.3 dB |
    | **Surfels, 8 rays, 64k pool (scene default)** | 10.1 | **35.6 dB** | 39.2 dB | **0.46** | 35.7 dB | **36.4 dB** |
    | Path traced, 2 bounces | 16.3 | 32.5 dB | 35.0 dB | 0.65 | 31.2 dB | 31.2 dB |

    Radiance cascades, the best choice in the Cornell room, lose 10 dB here: their probes sit on a screen grid and are interpolated across the edges of hundreds of small objects. Surfels live on the surfaces themselves. So the stress scene defaults to surfels, with 8 rays (no loss against 16 on still frames, 2 ms faster) and a 64k pool (a 32k pool runs short during camera moves: +2 dB). Sampled lights cost the GI nothing: every method scores within 0.15 dB of its score with every light traced, and the path tracer gains 0.9 dB.
  * **Upscalers in the stress scene** (3× from 640×400, against supersampled 1920×1200 frames):

    | | Albedo static | Flicker | Albedo moving | Camera move | Direct static | Direct moving |
    |---|---|---|---|---|---|---|
    | Custom (TAAU) | **43.2 dB** | 0.96 | **35.7 dB** | **35.3 dB** | 35.1 dB | 31.4 dB |
    | MetalFX temporal | 41.8 dB | **0.33** | 34.9 dB | 34.7 dB | **35.6 dB** | **31.8 dB** |

    The custom upscaler stays sharper and better in motion, but on a still frame full of small objects it flickers three times as much as MetalFX (on the Cornell room it was 0.05). Objects narrower than an input pixel show up only in some jitter phases, so the colour clip, which trusts the current frame, removes them and they pop back later. Turning off the clip's history cut removes the flicker (0.21) but costs 1.2 dB static and 0.9 dB moving; dead zones and a min/max hull test traded the two without winning. MetalFX and FSR 2 protect such pixels with thin-feature "locks", which this upscaler doesn't have yet.
* **Custom ray tracing vs Metal's** (M1 Max, stress scene, 32 lights, moving, custom upscaler 3× from 640×400).
  * Whole frames (`METALGI_BENCH_SPLIT=0`, two alternating runs each):

    | | Metal | Custom |
    |---|---|---|
    | Cornell room, default | 2.40–2.45 ms | 2.34–2.52 ms |
    | Stress, 400 objects, scene default (surfels) | 10.09 ms | **8.21 ms** |
    | Stress, 2000 objects, radiance cascades | 12.59 ms | **9.60 ms** |

  * Per pass (`METALGI_BENCH=rt`), Metal → custom:

    | Pass | 400 objects | 2000 objects |
    |---|---|---|
    | Path-traced trace (primary ray + 2 bounces + NEE) | 9.40 → **6.72 ms** | 16.41 → **10.65 ms** |
    | Many-light shadow rays | 4.55 → **3.38 ms** | 7.76 → **4.98 ms** |
    | Surfel trace | 4.60 → **3.52 ms** | 7.54 → **4.85 ms** |
    | Radiance-cascade trace | 1.37 → **1.21 ms** | 2.41 → **1.80 ms** |
    | Light maps | 0.56 → 0.54 ms | 1.05 → 0.99 ms |
    | Top-level tree | 0.07 → 0.08 ms | 0.08 → 0.12 ms |

  * Quality (`METALGI_BENCH=stressq`): every direct-light, GI and upscaler score is within ±0.2 dB of Metal's.
  * Paused frames differ from Metal's by RMS 0.02–0.3 of an 8-bit level. The few larger differences are soft-shadow pixels where an any-hit shadow ray reports a different occluder, which shifts the penumbra estimate.
  * What mattered, in order:
    * **One loop for both levels.** Nesting the per-instance bottom-level loop inside the top-level loop let SIMD lanes in different levels wait on each other. Merging them (entering an instance pushes a marker and switches the ray to object space; popping the marker switches back) almost halved closest-hit cost: path-traced trace 12.97 → 6.73 ms at 400 objects. Before that, the custom tracer was 35% *slower* than Metal on closest hits.
    * **Static objects stay instances** in their own tree, built once, as with Metal (merging them into one mesh loses the walls' tight boxes).
  * What didn't help:
    * Skipping postponed subtrees that start beyond the closest hit (a second stack of entry distances) cost 15%: the extra stack traffic outweighs the boxes it skips.
    * A smaller stack (32 entries) changed nothing.
    * Bigger leaves (a higher SAH traversal cost) were 2–4% slower.
    * A watertight triangle test (Woop et al.) was 30% slower and changed no image. The upscaled moving frames that differ from Metal's along silhouettes come from depth and motion differing in the last float bits, which the upscaler's depth-edge and clip decisions amplify; native frames match bit for bit.
    * An SAH-built moving-object tree (`METALGI_RT_BUILD=cpu`) traces only 4–7% faster than the GPU LBVH.
* MetalFX's built-in denoiser (`MTLFXTemporalDenoisedScaler`) also runs on an M1 Max under macOS 27, but it costs 4.2 ms at 640×400 → 1920×1200. That's more than this project's SVGF denoiser plus the temporal scaler it would replace (about 1.5 ms together). On M3 and later, with ray tracing hardware, it may be worth swapping passes 3, 4 and 6 for it.

* **glTF gallery** (11 Tripo models, 17.9M triangles, 67 textures of up to 4096², M1 Max, 640×400; `METALGI_BENCH=gallery`, `Tools/eval/gallery.py`).
  * Virtual geometry against full-detail meshes, same scene and custom tracer (GPU ms per frame):

    | | Full detail | VG 1 px | VG 2 px |
    |---|---|---|---|
    | Triangles traced | 17.9M | 0.4M (overview), 1.1M (close-up) | 0.18M |
    | Geometry memory | ~1.5 GB (BLAS + vertex buffers) | 40 MB (overview), 108 MB (close-up) | 18 MB |
    | Overview, direct light | 4.33 | 4.09 | 3.81 |
    | Overview, surfel GI | 8.42 | 8.46 | 7.92 |
    | Close-up, surfel GI | 12.72 | 13.73 | — |
    | Camera fly-through (3× upscaled) | 16.63 | 17.54 | — |

    About the same speed, at 3–4% of the memory. The cut updates in the background in 30–150 ms when it changes (the fly-through rebuilt 900 instance BLASes). Quality: the cut is crack-free and looks the same. Against path-traced references it scores 29.7 dB at 1 px, 31.5 dB at 0.5 px and 35.0 dB at full detail on the overview; the single sample per pixel makes texture detail alias, so sub-pixel geometry changes cost dB there (blurred 4×4, VG 1 px and full detail agree to 41 dB).
  * PBR against the path-traced references (close-up, full detail): 32.4 dB with surfel GI, 30.7 dB with cascades, 31.1 dB path traced. Average colour per region matches within 0.5% on the glossy floor, 1–3% on the steel plinths, about 5% on the bronze owl. The reflection pass costs 0.4 ms on a still frame and 0.6–1.0 ms in motion.
  * Texture streaming: 14 MB resident from the overview and 46–65 MB close up, against 2.6 GB for all levels (or 711 MB capped at 2048). Images match fully resident 4K textures at 56–77 dB. Uploads are capped at 48 MB per frame.
  * What mattered:
    * **One SAH tree per model over the cut, not a tree of clusters.** The first runtime selected the cut on the GPU, streamed cluster groups into a 768 MB pool (buddy allocator, LRU, Nanite's residency rules) and built a per-frame LBVH over the selected clusters, each with its own little BVH. It works (`METALGI_VG_MODE=clusters`) but traces 2× slower than full detail. Rays visit 8.6 nodes per ray inside models instead of 3.8, because cluster boxes overlap. Splitting the tree per instance to drop the per-cluster transform changed nothing, and an offline SAH over the same clusters would only save 15%.
    * **Simplification that keeps going:** locking only group borders (not the mesh's own open edges), letting seam and border vertices slide along their seams, a relaxed pass across UV seams for fragmented Tripo atlases when the strict one gets stuck, passing stuck groups up a level, and filling clusters spatially. That took the DAG from 883 root groups per model (full-detail fragments, always drawn) to one 366-triangle root, and the cut from 62k clusters to 3.9k.
    * **Texture levels from the largest UV stretch** (as GPUs do) and a histogram instead of a minimum: UV slivers and close self-reflections had asked for 4K mips of models 100 px tall (600 MB resident instead of 14).
  * In close-ups, Metal's intersector on the full-detail meshes is about 12% faster than this tracer with virtual geometry (11.1 vs 13.7 ms); from the overview, and in the stress scene, the custom tracer is faster.
  * Known issue: surfel GI shows a jagged bright patch on the gallery floor while the camera moves (with or without virtual geometry).

## Where to go next

1. **Thin-feature locks for the custom upscaler:** in busy scenes it flickers 3× as much as MetalFX on still frames (see the stress test). Marking pixels where a thin, high-contrast feature keeps appearing and protecting their history from the clip, as FSR 2 does, would fix that.
2. **Many lights, steadier:** with more than 4 lights, still frames still flicker more than with one ray per light, even with temporal reuse (see the stress test). Spatial reuse would pool neighbours' shadow rays, which the shadow denoiser partly does already; a denoiser that tracks the variance of fractional visibility over time (instead of assuming 0/1 samples) is the likelier fix. Per-tile light lists would stop the light-picking loop from growing with the light count.
3. **Faster custom traversal:**
   * Collapse the binary trees into 4-wide nodes, so a ray tests four boxes per fetch and pushes less. The GPU LBVH would need a collapse pass too, or the single loop would diverge again.
   * Give the LBVH SAH-quality top levels, for example with treelet restructuring or PLOC: a CPU SAH tree traces 4–7% faster.
   * With 2000 objects the frame still costs 1.4 ms more than with 400; sorting secondary rays by direction for coherence is the other thing to try.
4. **Better GI caching:** surfels and radiance cascades fall back to the scene's average indirect light at points no surfel or screen pixel covers. A coarse world-space irradiance volume (or DDGI probes) would give those points real local values.
5. **Deforming meshes:** update vertices in a compute pass, then refit that mesh's bottom-level tree with a bottom-up box pass like `rtFitKernel` (or call `refit` on its BLAS with the Metal tracer).
6. **Specular, better:** reflections reproject with surface motion, so glossy reflections smear a little in camera moves (virtual-point reprojection would fix that), and secondary hits treat specular as diffuse.
9. **Virtual geometry:** a GPU-built (or treelet-optimized) BLAS over the cut would let the cut update every frame; LOD cross-fades would hide the rare pop; the Metal tracer could build BLASes over the cut too.
10. **Texture compression:** ASTC or BC7 would cut the texture cache (2.5 GB) and streaming bandwidth by 4×.
7. **Rasterized G-buffer:** generate primary visibility with a raster pass to save one ray per pixel.
8. **Custom upscaler at 2× and 1.5×:** it matches MetalFX in motion at 3× but trails by up to 0.7 dB in camera moves at lower factors. Tuning per factor (its motion cuts are scaled by the factor today), or a per-pixel disocclusion test that doesn't misfire on jittered edges, would be the next step.
