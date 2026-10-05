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
| Scoring against MetalFX | `METALRENDERER_BENCH=neuralq` + `Tools/eval/hwrt.py` |

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
frame (the long part: ~70 s each on an M1 Max, 6–9 min for the showcase's and the stress building's; ~1,500 of them). Stop it any time; run it again to carry on. The clip
list is `METALRENDERER_DATASET` (default: 11 handmade scenes × 4 clips, the stress building's 4 zones, 24 random rooms
and the showcase's 11 models, each on its own set; 20 frames a clip, 8 for the stress building and the showcase; 512
spp; keys in `Benchmark.DatasetSpec`). Scenes with glTF models trace them at full detail and every clip
runs without the lens (bloom, depth of field), in both runs (`DatasetClip.shared`).

On a Mac with hardware ray tracing (M3 and later), first time one reference with the Metal tracer, which may be much
faster: `METALRENDERER_DATASET="scenes=cornell,clips=1,frames=1,spp=512" METALRENDERER_RT=metal Tools/neural/make-dataset.sh -d /tmp/try`
and compare `dataset/run.log` times. `METALRENDERER_RT=metal` then goes in front of the real run.

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
.venv/bin/python train.py ../../dataset --val market,forest --out runs/first
```
Market and forest are held out, so validation measures how the net does on scenes it never saw. Each epoch prints
the net's PSNR and flicker next to MetalFX's on the same frames. Checkpoints: `runs/first/best.pt`, `last.pt`
(`--resume`). The model (`model.py`): a recurrent U-Net at the render resolution over the noisy light, the guides and
last frame's output (warped by the motion, folded 3×3 into the render resolution); ~274k parameters.

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
.claude/skills/offscreen/scripts/render.sh -m neuralq -o /tmp/nq METALRENDERER_GI_REFS=0 && python3 Tools/eval/hwrt.py /tmp/nq
```

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
