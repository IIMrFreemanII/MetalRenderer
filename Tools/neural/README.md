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
nohup Tools/neural/make-dataset.sh > /dev/null 2>&1 &   # progress: dataset/run.log
```
Renders offscreen (no window). First every clip's noisy frames (minutes), then a path-traced reference for every
frame (the long part: 1,660 of them, 62 GB; 6–54 s each on an M4 Max, ~10 h in all; ~70 s each on an
M1 Max, 6–9 min for the showcase's and the stress building's). Stop it any time; run it again to carry on. The clip
list is `METALRENDERER_DATASET` (default: 11 handmade scenes × 4 clips, the stress building's 4 zones, 24 random rooms,
12 bulb rooms (`bulbrooms=`: random rooms at night strung with dozens to hundreds of small bulbs, the light of the night
market the other rooms don't have) and the showcase's 11 models, each on its own set; 20 frames a clip (`stressframes=` / `showcaseframes=` cut those two); 512
spp; keys in `Benchmark.DatasetSpec`). Scenes with glTF models trace them at full detail and every clip
runs without the lens (bloom, depth of field), in both runs (`DatasetClip.shared`).

Each scene also has **paused clips** (`<scene>-<seed>-p<n>`; `pausedclips=`, `pausedframes=`, default 3 × 100 frames):
a still camera on the paused scene, at a moment (room, model, stress zone or the building's own camera) of its own. Every frame is new noise over
the same image, so it needs one reference, frame 0's, for all 100: long, still views cost almost nothing to add, and
they are what teaches the net to keep accumulating while a view holds still, as MetalFX does. The stress building has 2
more (`stresspausedextra=`): every zone and the camera over the aisle, where a still view flickers most.

And **held clips** (`<scene>-<seed>-h<n>`; `heldclips=`, `heldframes=`, `heldrefs=`, default 1 × 100 frames): a still
camera on the scene as it moves (objects, lights), with references for the last 20 frames only (the 80 before only
build the history). The app runs for hundreds of frames: a net trained on 20-frame runs alone let moving objects and the
light around them lag behind there (Cornell, objects moving: 25 dB against MetalFX's 31), and these taught it to drop
stale history.

`need=<buffer>` renders the noisy frames again of clips saved before that buffer existed (their cameras and times come
out the same, so their references stay): `need=extra` brought every clip the v2 inputs (below).

Macs with hardware ray tracing (M3 and later) render references much faster. To time a new scene first:
`METALRENDERER_DATASET="scenes=cornell,clips=1,frames=1,spp=512" Tools/neural/make-dataset.sh -d /tmp/try`.

References have no firefly clamp, so a rare sample overflows the half-float light textures; the averaging kernels
count it as 65504 (`finiteSample`, Output.metal). Datasets rendered before that fix (6 Oct 2026) have NaN or zeroed
pixels next to bright lights; `train.py` leaves non-finite reference pixels out of its loss and scores.

**Layout** (`dataset/`, gitignored): a folder per clip, `<scene>-<seed>-<clip>`, holding per frame `fNNNN.json`
(time, camera, jitter, exposure, sizes) and float16 arrays `fNNNN-<buffer>.npy`:
- render resolution: `color` (noisy linear light, before exposure), `albedo`, `specular` (specular albedo),
  `normal` (world normal + view depth, sky −1), `depth` (reversed Z), `motion` (previous minus current pixel), `roughness`;
  and the same light in parts (the composite's FLAG_SPLIT_OUTPUT): `diffuse` (light / albedo), `specularlight`
  (specular light / specular albedo), `extra` (emission and fog in-scatter; alpha: how much of last frame shows the
  surface, SVGF's reprojection test), with `color = albedo * diffuse + max(specular, 1e-3) * specularlight + extra.rgb`;
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
(0.5): at 2 the net froze anything a still camera saw, moving objects included. Held clips the same way, a batch every
`--held-every` (4), a warm-up of up to `--held-length` - `--length` frames, then their last `--length`. Checkpoints: `best.pt` (moving and still validation alike), `last.pt`
(`--resume`); `--init <checkpoint>` starts from another run's weights with a new schedule. The model (`model.py`): a
recurrent U-Net at the render resolution over the noisy light, the guides and last frame's output (warped by the
motion, folded 3×3 into the render resolution); `--widths` 32,48,64 is ~274k parameters, 64,96,128 ~968k, a level per
width. Its architecture, kept in the checkpoint: `--inputs v2` (the light in parts and the history validity),
`--head kernel` (with v2: softmax filter weights over the 3×3 noisy render pixels and the history for each part of the
light, and the surface's colours accumulated over the jittered frames, instead of a colour of its own), `--warp
bicubic` (cubic history, PyTorch's grid_sample, a = -0.75). `--augment` mirrors, turns and recolours each training sample (motion and jitter turn
with it). `runs/v2-screen.sh` (local) compares them one change at a time. The app runs every architecture: `export.py` writes
it into the .nnw (`arch`), NeuralUpscaler reads it (v2 nets get the composite's light in parts); NeuralUpscalerTests
checks the kernels against PyTorch for the first net and a v2 one (golden-v2.nnw).

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

The shipped net (Assets/Neural/denoiser.nnw) is v2: `--inputs v2 --head kernel --warp bicubic --widths
64,96,128,160` (2.07M parameters), 25 screening + 75 epochs, then fine-tuned with the held clips. Against MetalFX in
the app (`neuralq`, PSNR in dB against 4-bounce references; flicker of a still frame):

| | static | flicker | moving | camera |
|---|---|---|---|---|
| Cornell, ours / MetalFX | 32.20 / 32.01 | 0.54 / 1.11 | 31.41 / 31.43 | 31.16 / 31.40 |
| stress, ours / MetalFX | 25.78 / 24.57 | 0.78 / 0.62 | 25.25 / 24.43 | 25.04 / 24.85 |

and on the held-out market and forest clips (infer.py, whole clips) 24.75 / 24.48 moving, 26.82 / 26.19 still. The
first net (v1, 968k) was better in Cornell (32.55, 32.19 moving) and worse elsewhere (stress 24.73, market and forest
24.04 / 25.32). Screening (25 epochs each, the gap to MetalFX on the held-out clips, moving / still): v1 -0.99 / -1.56,
+ augmentation -1.25 / -1.99, + v2 inputs -1.27 / -1.95, + kernel head -0.21 / -0.43, + bicubic and a fourth level
-0.11 / -0.11. Tried and dropped: gating the history by its validity (validity is noisy under jitter in foliage and
thin lights: still views flickered 10x), capping the history's weight (helped the lag, cost the still views; the held
clips fixed it instead). The Metal kernels match PyTorch to 75-83 dB on the app's own frames.

Speed (M4 Max, 640×400 → 1920×1200, `neuralq`, GPU total): ~40 ms a frame (was ~237 ms; MetalFX 1.75 ms). The
convolutions are implicit matrix products on simdgroup matrices (neuralConvKernel: a threadgroup computes 8 rows × 8
pixels × 32 output channels, input channels 8 at a time through threadgroup memory with their repacked weights,
NeuralWeights.packed); the passes `neural in` (~2.4 ms: the warp, the input tensor), `neural` (~35 ms: the U-Net),
`neural out` (~1.2 ms: the head). Tried and slower: 64 output channels a threadgroup (registers), 16 input channels
a step (threadgroup memory); sharing the step's memory with the output staging and 8 simdgroups a threadgroup each
helped ~1 ms.

Next:
1. Speed: the U-Net runs at ~10 TFLOPS; the head (351 outputs, ~30% of the work) and enc0.0 (233 inputs, 207 of them
   last frame's state) are the big layers: per-layer timings, then a slimmer head or state.
2. Use it where MetalFX's denoiser isn't available (today those GPUs fall back to 1× + SVGF): Capabilities.
