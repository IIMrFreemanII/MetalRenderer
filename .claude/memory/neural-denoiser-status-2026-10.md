---
name: neural-denoiser-status-2026-10
description: "Our own neural denoising upscaler (Oct 2026): what's built and verified, measured numbers, and what's next"
metadata:
  type: project
---

On 2026-10-05 the user started replacing/complementing MetalFX's `MTLFXTemporalDenoisedScaler` with our own net,
trained on this app's scenes. Their choices: train on the Mac (PyTorch MPS), run it with hand-written Metal kernels,
joint denoise + 3× upscale first, **quality first, optimise later**. Branch `claude/custom-denoise-upscale-34b935`
(pushed, not merged). The how-to is `Tools/neural/README.md`.

Built and verified on the M1 Max:
- Dataset exporter (`Benchmark+Dataset.swift`): `METALRENDERER_BENCH=dataset` (noisy inputs, MetalFX's output, a
  JSON row per frame) then `datasetref` (supersampled path-traced linear references at 1920×1200, resumable,
  clip-major order). Runner: `Tools/neural/make-dataset.sh`. References line up (MetalFX ~33 dB vs them in Cornell).
- Random training rooms (`Scene+Training.swift`, `SceneKind.randomRoom`), seeded, with the gallery's models.
- The showcase (main's scene) is in the dataset too: one clip per Assets/ model (`scene.showcase`), smaller drift,
  8 frames a clip (user's choice): its references took 6–9 min each on the M1 Max (fog volumes, full-detail models).
  `DatasetClip.shared` gives model scenes (rooms, gallery, showcase) full-detail meshes and a 4 GB texture budget, and
  turns the lens off, in both runs. SDF shapes were offered and declined by the user.
- Training pipeline `Tools/neural` (model.py recurrent U-Net, ~274k params; train/infer/export/view). Learns.
- `NeuralUpscaler.swift` + `Shaders/Neural.metal`, chosen by `RenderSettings.upscaler` (`METALRENDERER_GI=upscaler=neural`);
  `NeuralUpscalerTests` matches PyTorch to 0.11% and fails on deliberately broken kernels; MetalFX frames bit-identical.
- `neuralq` mode + `Tools/eval/hwrt.py` score it against MetalFX.

Dataset: started on the M4 Max on 2026-10-05 21:14 (`METALRENDERER_RT=metal`, default spec, 83 clips, 1,480
references, noisy pass 31 GB in 1 min; references 6–54 s each, ~8–10 h expected) into the repo's `dataset/`.
Found on 2026-10-06: references had NaN pixels (118 files) and channels squashed to 0 (11 more), all next to bright
lights in random rooms, the showcase and fog. Cause: references run without the firefly clamp, raw per-frame light is
half float (`direct`/`indirect`/`specular`, `upscaleColor`), so a sample over 65504 became inf and the running mean
NaN (and a later max(x, 0) made some of it 0). Fixed in Output.metal (`finiteSample`: inf counts as 65504, NaN as 0)
and the 129 references re-rendered; `train.py` also masks non-finite reference pixels out of loss and scores.
Trained on 2026-10-06 (M4 Max, ~1 min an epoch, --val market,forest), dataset-clip PSNR net / MetalFX:
- widths 32/48/64 (274k, `runs/first`, 50 epochs): 1-2 dB under MetalFX everywhere; mean colour right, detail soft.
- widths 64/96/128 (968k, `runs/wide`, 60 epochs; `--widths`, saved in the checkpoint): beats MetalFX on trained
  scenes (Cornell 31.7/31.0, sun 34.2/32.5, random rooms 30.5/29.0), not on held-out ones (forest 23.4/24.5, market
  22.4/26.6: its hundreds of small lights look like no training scene). Exported to Assets/Neural/denoiser.nnw;
  in the app (`neuralq` + hwrt.py) 120 ms a frame, Cornell 32.0 vs 34.6 static, stress 25.6 vs 27.3 with flicker
  3.1 vs 0.65: MetalFX keeps accumulating while a view holds still, the net (trained on 8-frame runs from no
  history) doesn't. Not history at the start, though: the net is behind from frame 0 and gains 0.3 dB in 20 frames.
2026-10-07, the user's choices: whole 20-frame sequences, train on every scene and validate on seed-2 clips of market
and forest (`--val market-2,forest-2`; `common.matches` takes scene or scene-seed prefixes). `runs/long` (wide,
--length 20, 60 epochs, ~2 min an epoch, still improving at the end): forest-2 24.3/24.0 (beats MetalFX), market-2
25.2/27.3, Cornell 31.8/31.0, sun 33.9/32.5, stress 27.2/26.6. Exported (Assets/Neural/denoiser.nnw). In the app
still behind: Cornell 31.2 static / 30.8 moving vs 34.6 / 32.5, stress 26.2 vs 27.3 (flicker 2.3 vs 0.65). Likely
cause: app runs are ~90+ frames, training clips 20.
Paused clips built 2026-10-07 (`<scene>-<seed>-p0`, 100 frames, one reference; `pausedclips=`/`pausedframes=`; train.py
`--paused-every 4 --paused-length 80`, "still" scores, `--init`). `runs/still` (fine-tune of runs/long, 40 epochs at
1e-4, ~4 min an epoch, stopped at 38 when the session ended) improved everything: Cornell 32.2/31.0, paused 31.8/31.1;
stress 27.9/26.6, paused 29.6/28.0; held-out forest-2 24.4/24.0, paused 24.9/26.4; market-2 25.7/27.3, paused
26.3/28.5. In the app (exported): stress static 27.0 vs 27.3 (flicker 1.7 vs 0.65), Cornell still 31.1 vs 34.6. The
Cornell error map: grain left on saturated walls (dark channels: the loss is in log1p light, where they weigh little,
while ACES + sRGB display brightens them) and outlines at edges and small lights. Next idea: a display-space loss term.
Not done: a net that beats MetalFX
(only a 1-minute smoke model: 16.7 dB vs MetalFX 34.6), speed (plain kernels ~90 ms/frame at 1920×1200), the
fallback for GPUs without MetalFX's denoiser.

**Why:** the user wants a denoiser trained on their own scenes that they control.
**How to apply:** next steps in order: make the dataset (`make-dataset.sh`, detached) and let **all** references
finish (the user's choice, 2026-10-05: training shares the GPU and would slow both) → train
(`train.py dataset --val market,forest`) → export → `neuralq` → speed work (performance skill).
Ping the user when training starts ([[feedback-ping-training]]). The stress building is in, 4 zones × 8 frames ([[feedback-no-stress-references]]).
