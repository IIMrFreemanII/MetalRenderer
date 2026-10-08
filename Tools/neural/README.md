# Our own denoising upscaler

A neural net that does what MetalFX's `MTLFXTemporalDenoisedScaler` does — denoise the 1-sample-per-pixel light and
upscale it 3× (640×400 → 1920×1200) — trained on this renderer's own scenes, and run by our own Metal kernels.
It sits next to MetalFX as a choice (`RenderSettings.upscaler`), so the two can be compared.

| Piece | Where |
|---|---|
| Training data exporter | `Sources/MetalRenderer/Benchmark+Dataset.swift` (`METALRENDERER_BENCH=dataset` / `datasetref`), `Tools/neural/make-dataset.sh` |
| Random training rooms | `Sources/MetalRenderer/Scene+Training.swift` (`SceneKind.randomRoom`, "Random room (training)") |
| Model, training, export | `Tools/neural/` (PyTorch, runs on the Mac's GPU through MPS) |
| Inference in the app | `Sources/MetalRenderer/NeuralUpscaler.swift`, `Shaders/Neural.metal` |
| Kernels = PyTorch check | `Tests/MetalRendererTests/NeuralUpscalerTests.swift` + `Neural/golden.nnw` |
| Scoring against MetalFX | `METALRENDERER_BENCH=neuralq` + `Tools/eval/neural.py` |

## Setup

```bash
swift build -c release
uv venv Tools/neural/.venv --python 3.12
uv pip install -p Tools/neural/.venv -r Tools/neural/requirements.txt
```

## 1. Make the dataset

```bash
METALRENDERER_RT=metal nohup Tools/neural/make-dataset.sh > /dev/null 2>&1 &   # progress: dataset/run.log
```
Renders offscreen (no window). First every clip's noisy frames (minutes), then a path-traced reference for every
frame (the long part: 1,660 of them, 62 GB; 6–54 s each on an M4 Max with the Metal tracer, ~10 h in all; ~70 s each on an
M1 Max, 6–9 min for the showcase's and the stress building's). Stop it any time; run it again to carry on. The clip
list is `METALRENDERER_DATASET` (default: 11 handmade scenes × 4 clips, the stress building's 4 zones, 24 random rooms
and the showcase's 11 models, each on its own set; 20 frames a clip (`stressframes=` / `showcaseframes=` cut those two); 512
spp; keys in `Benchmark.DatasetSpec`). Scenes with glTF models trace them at full detail and every clip
runs without the lens (bloom, depth of field), in both runs (`DatasetClip.shared`).

Each scene also has **paused clips** (`<scene>-<seed>-p<n>`; `pausedclips=`, `pausedframes=`, default 3 × 100 frames):
a still camera on the paused scene, at a moment (room, model, stress zone or the building's own camera) of its own. Every frame is new noise over
the same image, so it needs one reference, frame 0's, for all 100: long, still views cost almost nothing to add, and
they are what teaches the net to keep accumulating while a view holds still, as MetalFX does. 42 of them: ~4,200 noisy
frames (~95 GB, a few minutes) and 42 references.

`METALRENDERER_RT=metal` is for Macs with hardware ray tracing (M3 and later): on an M4 Max it renders the same reference
as the custom tracer (92 dB apart) in ~60% of the time. On an M1 Max leave it out. To time a new scene first:
`METALRENDERER_DATASET="scenes=cornell,clips=1,frames=1,spp=512" METALRENDERER_RT=metal Tools/neural/make-dataset.sh -d /tmp/try`.

References have no firefly clamp, so a rare sample overflows the half-float light textures; the averaging kernels
count it as 65504 (`finiteSample`, Output.metal). Datasets rendered before that fix (6 Oct 2026) have NaN or zeroed
pixels next to bright lights; `train.py` leaves non-finite reference pixels out of its loss and scores.

**Layout** (`dataset/`, gitignored): a folder per clip, `<scene>-<seed>-<clip>`, holding per frame `fNNNN.json`
(time, camera, jitter, exposure, sizes) and float16 arrays `fNNNN-<buffer>.npy`:
- render resolution: `color` (noisy linear light, before exposure), `albedo`, `specular` (specular albedo),
  `normal` (world normal + view depth, sky −1), `depth` (reversed Z), `motion` (previous minus current pixel), `roughness`;
- output resolution: `metalfx` (MetalFX's output, the baseline to beat), `reference` (supersampled path tracing).

**Look at it:** `Tools/neural/.venv/bin/python Tools/neural/view.py dataset` writes `dataset/preview/*.png`: noisy
input, MetalFX, reference on top; albedo, normals, motion below.

## 2. Train

```bash
cd Tools/neural
.venv/bin/python train.py ../../dataset --val market-2,forest-2 --widths 64,96,128 --length 20 --out runs/long
```
`--val` holds out scenes (`market`) or one seed's clips of them (`market-2`, rendered with
`METALRENDERER_DATASET="scenes=market|forest,clips=2,frames=20,seed=2" make-dataset.sh`): the app runs these scenes, so
validating on new clips of them measures what it will show. Each epoch prints the net's PSNR and flicker next to
MetalFX's on the same frames, and with paused clips held out, "still" scores: the last 20 of `--paused-length` (80)
frames. Paused clips train in a batch every `--paused-every` (4; the shipped net 3): a random warm-up of up to 60 frames
without gradients, then `--length` frames with. Their frame-to-frame term has its own weight, `--paused-temporal`
(0.5): at 2 the net froze anything a still camera saw, moving objects included. Checkpoints: `best.pt` (moving and still validation alike), `last.pt`
(`--resume`); `--init <checkpoint>` starts from another run's weights with a new schedule. The model (`model.py`): a
recurrent U-Net at the render resolution over the noisy light, the guides and last frame's output (warped by the
motion, folded 3×3 into the render resolution); `--widths` 32,48,64 is ~274k parameters, 64,96,128 ~968k.

```bash
.venv/bin/python infer.py runs/first/best.pt ../../dataset --scenes market,forest --png out/   # whole clips, side by side
```

## 3. Use it in the app

```bash
.venv/bin/python export.py runs/first/best.pt            # → Assets/Neural/denoiser.nnw (Git LFS)
.venv/bin/python export.py --golden ../../Tests/MetalRendererTests/Neural/golden.nnw   # only if model.py changed
```
Then choose "Neural (ours)" in the panel's Upscaler popup, or `METALRENDERER_GI=upscaler=neural`
(`METALRENDERER_NEURAL=<file>` for other weights). Score it against MetalFX:
```bash
.claude/skills/offscreen/scripts/render.sh -m neuralq -o /tmp/nq && Tools/neural/.venv/bin/python Tools/eval/neural.py /tmp/nq
```
Both upscale the app's own GI (radiance cascades, as the dataset's frames) against 4-bounce references. To check the
kernels against PyTorch on real frames, run the dataset mode with `METALRENDERER_GI=upscaler=neural`: each frame then
saves our net's output (`neural.npy`) where MetalFX's would go.

**Demo video:** `Tools/neural/demo-video.sh` (→ `renders/denoiser-demo.mp4`, ~20 min) renders the `denoisedemo` mode
offscreen, each scene's camera move three times (the net's input: 1 sample, 640×400, no denoiser; MetalFX's denoising
scaler; ours), and puts them in one 1920×1200 frame, a third each, labelled: the stress building's tour, the Cornell
room, the night market's street, a showcase model; the lens off, so nothing blurs what they differ in.

## Status (Oct 2026)

Done and verified on the M1 Max: the exporter (references line up with the noisy frames; MetalFX scores ~33 dB
against them in the Cornell room), the training pipeline (runs; learns), the Metal kernels (match PyTorch to 0.11%;
the test fails on deliberately broken kernels), the in-app path (`neuralq` runs; MetalFX frames bit-identical to
before), random rooms. Not done: **no trained net yet** (only a one-minute smoke test, 16.7 dB vs MetalFX's 34.6).

Next:
1. Make the dataset, let every reference finish (training and reference rendering would share the GPU), then
   train (quality first).
2. Speed: the kernels are the plain first version (~90 ms a frame at 1920×1200); simdgroup_matrix convolutions,
   fused layers, then a smaller net (the `performance` skill).
3. Use it where MetalFX's denoiser isn't available (today those GPUs fall back to 1× + SVGF): Capabilities.
