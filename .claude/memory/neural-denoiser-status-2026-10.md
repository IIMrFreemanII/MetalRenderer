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
- Training pipeline `Tools/neural` (model.py recurrent U-Net, ~274k params; train/infer/export/view). Learns.
- `NeuralUpscaler.swift` + `Shaders/Neural.metal`, chosen by `RenderSettings.upscaler` (`METALRENDERER_GI=upscaler=neural`);
  `NeuralUpscalerTests` matches PyTorch to 0.11% and fails on deliberately broken kernels; MetalFX frames bit-identical.
- `neuralq` mode + `Tools/eval/hwrt.py` score it against MetalFX.

Not done: the dataset (regenerate on the M4 Max: ~1,300 references, ~70 s each on the M1 Max), any real training
(only a 1-minute smoke model: 16.7 dB vs MetalFX 34.6), speed (plain kernels ~90 ms/frame at 1920×1200), the
fallback for GPUs without MetalFX's denoiser.

**Why:** the user wants a denoiser trained on their own scenes that they control.
**How to apply:** next steps in order: make the dataset (`make-dataset.sh`, detached) and let **all** references
finish (the user's choice, 2026-10-05: training shares the GPU and would slow both) → train
(`train.py dataset --val market,forest --exclude stress`) → export → `neuralq` → speed work (performance skill).
Ping the user when training starts ([[feedback-ping-training]]). Keep the stress hall out ([[feedback-no-stress-references]]).
