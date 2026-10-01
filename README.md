# MetalGI

A minimal real-time ray tracer for macOS and Metal, with dynamic lights and global illumination.
It's built for Apple Silicon and tuned for an M1 Max.

* **Dynamic scenes:** objects and sphere lights move every frame. Two scenes ship (pick one in the settings panel): a small Cornell-style room, and a **stress test** hall with up to 2000 moving objects and 256 moving lights (see below). The top-level acceleration structure is refit every frame and fully rebuilt every 16 frames, and each mesh's bottom-level acceleration structure is built once.
* **Direct light:** ray-traced soft shadows. With up to 4 lights, each light gets one shadow ray per pixel. With more, lights are split into 4 colour groups, and each pixel picks one light per group, weighted by how much light it would get from it unshadowed, then traces one shadow ray to it. The cost is then 4 rays per pixel whatever the light count.
* **Global illumination, three methods** (switch with **M** or in the settings panel):
  * **Radiance cascades (default):** probes on a screen grid trace world-space rays over distance intervals that grow 4× per cascade. The cascades are merged top-down, giving each probe its incoming light without noise.
  * **Surfels:** a pool of small disks on visible surfaces, after EA SEED's GIBS. Each disk traces 16 rays per frame and accumulates irradiance over time. Pixels average the disks around them.
  * **Path traced:** a 1-sample-per-pixel diffuse path is traced for 1 to 8 bounces. Each bounce samples one light directly (next-event estimation), picked in proportion to its unshadowed light there, and picks up sky light. The result is denoised.
  * Surfels and radiance cascades get **multi-bounce** light, and light their ray hits from per-light **light-visibility maps**, so they need no shadow rays.
* **Light-visibility maps:** each frame, every light traces a 128×128 map of the distance to the nearest geometry in each direction (smaller beyond 16 lights, so all the maps together always cost about as much as 16). Secondary hits look up their shadowing there: from every light with up to 8 lights, otherwise from 4 lights picked by their unshadowed light. The path tracer can also use these maps for its bounces ("light bounces from light maps").
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

Use `METALGI_BENCH=stress` to time the stress scene against light count (1 to 256), object count (0 to 2000) and GI method, and `METALGI_BENCH=stressq` to score its direct light at 32 and 128 lights, and its final image, against converged references. `METALGI_SCENE=stress,objects=400,lights=32` loads the stress scene in every setting of any mode. `METALGI_LIGHTS=all` traces one shadow ray per light again (the brute-force baseline), `METALGI_GI=lightrays=2` sets the shadow rays per light group, and `METALGI_TLAS=<frames>` sets the TLAS rebuild interval (1 = every frame). `METALGI_BENCH_ONLY="32 lights|camera"` runs only the settings whose names contain one of these strings.

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
| R | Hot-reload `Shaders.metal` |
| Tab, ⌘, | Show or hide the Render Settings panel |

The window title and the settings panel show the resolution, frame rate and GPU time. The panel never takes keyboard focus, so the keys above keep working while it's open, and changes you make with the keys show up in it.

### Scene settings

| Setting | Default | Effect |
|---|---|---|
| Scene | Cornell room | Cornell room (5 objects, 2 moving, 3 lights) or the stress test. Switching rebuilds the geometry and acceleration structures, which takes a few milliseconds, and picks that scene's GI defaults: radiance cascades for the Cornell room, surfels (8 rays, 64k pool) for the stress test. Reset to Defaults also uses the current scene's. |
| Objects | 400 | Stress test: objects in the hall, about 85% of them moving. Applied when you release the slider. |
| Lights | 32 | Stress test: moving sphere lights, 1 to 256. Their total power stays the same, so the brightness barely changes. |
| Shadow rays | 1 per group + reuse | With more than 4 lights: shadow rays per light group and pixel. "Reuse" keeps each pixel's light picks for up to 4 frames (ReSTIR-style temporal resampling): a third less flicker on still frames for about 0.7 ms. 2 rays per group halve the flicker and are the most accurate, for about 4 ms more at 400 objects. |

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
GPU 1  refit the instance acceleration structure (TLAS) over the per-mesh BLASes (rebuild every 16 frames)
    1b lightMapKernel  per-light distance maps (surfels, radiance cascades, path tracer with light maps)
    2  traceKernel     primary ray -> G-buffer (normal, depth, albedo, emission, motion, world position)
                       direct (up to 4 lights): 1 shadow ray per light (+ per-light visibility and penumbra width)
                       indirect (path traced): cosine-sampled path, NEE at every bounce
                       (lighting is stored without albedo so the denoiser can blur it freely)
    2c manyLightsKernel more than 4 lights: per light group, pick 1 light by unshadowed light, 1 shadow ray
                       (+ per-group visibility and penumbra width); manyLightsReuseKernel also resamples
                       against last frame's picks (default)
    2b surfels         transform -> grid (count, scan, scatter) -> trace -> gather + spawn -> lifecycle
       or cascades     probes -> trace + merge per cascade (top down) -> SH projection -> resolve
    3  shadowTemporalKernel  direct light: reproject + clamp per-light visibility, penumbra widths, tile classes
       shadowFilterKernel x3 edge-aware, penumbra-limited 3x3 passes (skips fully lit / shadowed tiles)
    3b temporalKernel  SVGF for indirect light: reproject last frame, reject disocclusions, blend, track variance
                       (surfel / cascade indirect light skips the denoiser unless you enable it)
    4  atrousKernel x4 edge-aware wavelet filter (step 1, 2, 4, 8)
    5  compositeKernel exact unshadowed light x visibility + indirect, x albedo + emission -> ACES tonemap
                       -> drawable (sRGB format: the GPU encodes), or with upscaling linear colour at render resolution
    6  upscale         taauKernel straight into the drawable, or MetalFX into a private texture + a copy
```

With radiance cascades, 2b and 3–4 don't depend on each other. The frame then uses one concurrent compute encoder and runs them in lock step, with a barrier after each step: light map + trace + probes, then temporal + the top cascade, each à-trous pass + the next cascade down, and so on. Small dispatches on M1 leave the GPU partly idle, so this overlap saves about 0.2 ms. The other GI methods run in order.

| File | What it holds |
|---|---|
| `Renderer.swift` | Metal setup, acceleration structures, per-frame encoding, input |
| `Settings.swift` | Every user-adjustable setting, with defaults and ranges |
| `SettingsPanel.swift` | The Render Settings panel |
| `Upscaler.swift` | MetalFX temporal (or spatial) scaler and the sub-pixel jitter sequence |
| `TemporalUpscaler.swift` | The custom upscaler's history textures and dispatch (`taauKernel`) |
| `SurfelGI.swift` | Surfel GI: surfel pool, spatial grid, per-frame passes |
| `RadianceCascades.swift` | Radiance cascades: probe textures, radiance atlases, per-frame passes |
| `BlueNoise.swift` | Void-and-cluster blue-noise generator |
| `Benchmark.swift` | Benchmark mode (`METALGI_BENCH`) |
| `Scene.swift` | The two scenes: meshes, materials, instances, animation paths, lights and their shadow-denoiser groups |
| `GPUTypes.swift` | Structs shared with the shaders. Their layout must match `Shaders.metal` |
| `Shaders.metal` | All GPU code |

## Notes for M1 / M2 Macs

M1 and M2 run Metal ray tracing without dedicated ray tracing hardware, so the ray budget is the main cost here:

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
* **Stress test** (M1 Max, radiance cascades and the custom upscaler 3× from 640×400 unless noted; whole-frame GPU ms, best of two `METALGI_BENCH=stress` runs with `METALGI_BENCH_SPLIT=0`). "Before" is one shadow ray per light with the TLAS rebuilt every 256 frames; the next row adds the 16-frame rebuild; "now" adds light sampling with reuse and the lighter spheres:

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
* MetalFX's built-in denoiser (`MTLFXTemporalDenoisedScaler`) also runs on an M1 Max under macOS 27, but it costs 4.2 ms at 640×400 → 1920×1200. That's more than this project's SVGF denoiser plus the temporal scaler it would replace (about 1.5 ms together). On M3 and later, with ray tracing hardware, it may be worth swapping passes 3, 4 and 6 for it.

## Where to go next

1. **Thin-feature locks for the custom upscaler:** in busy scenes it flickers 3× as much as MetalFX on still frames (see the stress test). Marking pixels where a thin, high-contrast feature keeps appearing and protecting their history from the clip, as FSR 2 does, would fix that.
2. **Many lights, steadier:** with more than 4 lights, still frames still flicker more than with one ray per light, even with temporal reuse (see the stress test). Spatial reuse would pool neighbours' shadow rays, which the shadow denoiser partly does already; a denoiser that tracks the variance of fractional visibility over time (instead of assuming 0/1 samples) is the likelier fix. Per-tile light lists would stop the light-picking loop from growing with the light count.
3. **Many objects:** in the stress test, frame time rises by 4.5 ms between 400 and 2000 objects (8.1 to 12.6 ms), because every ray crosses more overlapping instance boxes, mostly of moving objects. Merging static geometry didn't help (see the stress test). Grouping nearby moving objects into shared bottom-level trees that are refit each frame, or sorting secondary rays by direction for coherence, are the next things to try.
4. **Better GI caching:** surfels and radiance cascades fall back to the scene's average indirect light at points no surfel or screen pixel covers. A coarse world-space irradiance volume (or DDGI probes) would give those points real local values.
5. **Deforming meshes:** update vertices in a compute pass, then call `refit` on that mesh's BLAS each frame.
6. **Glossy materials:** add a GGX specular lobe, kept as a separate signal for the denoiser.
7. **Rasterized G-buffer:** generate primary visibility with a raster pass to save one ray per pixel.
8. **Custom upscaler at 2× and 1.5×:** it matches MetalFX in motion at 3× but trails by up to 0.7 dB in camera moves at lower factors. Tuning per factor (its motion cuts are scaled by the factor today), or a per-pixel disocclusion test that doesn't misfire on jittered edges, would be the next step.
