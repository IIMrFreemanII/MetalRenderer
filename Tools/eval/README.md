# Benchmark scorers

Python 3 scripts (numpy, Pillow) that score the PNGs a benchmark run saves against converged reference images in
`refs/<mode>/`. They print PSNR in dB (higher is better) and flicker, the RMS difference between two consecutive
frames of a still scene, in 8-bit levels.

```bash
METALRENDERER_BENCH=shadow METALRENDERER_GI_REFS=0 METALRENDERER_BENCH_DIR=/tmp/run .build/release/MetalRenderer
python3 Tools/eval/shadow.py /tmp/run
```

| Script | Benchmark mode | References |
|---|---|---|
| `shadow.py` | `shadow`: Cornell direct light, static / moving / camera move | `refs/shadow/` (4096 frames) |
| `gi.py` | `gi`: every GI method on Cornell (plus `mean`, the indirect light's brightness vs the reference) | `refs/gi/` (8-bounce path traced) |
| `stress.py` | `stressq`: stress scene, direct light at 32 / 128 lights, each GI method's final image and indirect light, the MetalFX denoiser at 3× | `refs/stress/` |
| `restir.py` | `restirq`: stress-scene direct light at 32 / 128 / 1024 / 4096 lights, each direct-light method; `restircheck`: ReSTIR without reuse vs every light traced, per light type (within the run) | `refs/restir/` (every light traced up to 1024; ReSTIR without reuse at 4096) |
| `restirgi.py` | `restirgicheck`: accumulated ReSTIR GI (no reuse, reuse, quarter budget) vs accumulated path tracing, indirect light, Cornell and stress hall (within the run) | — |
| `noise.py` | `denoise` (references from `noise`) | `refs/noise/` (render once, see below) |
| `hwrt.py` | `hwrtq`: MetalFX's denoising scaler at 3×, final image, Cornell and stress hall | `refs/hwrt/` (supersampled 1920×1200, path traced) |
| `pngdiff.py` | any two runs: per-image differences (did a refactor change the frames?) | — |
| `columns.py` | pipe a benchmark table in to pull out named columns | — |

Each mode's "ref …" settings render the references; once they exist, skip them with `METALRENDERER_GI_REFS=0`. When a run
does render them, the scorer copies them into `refs/<mode>/`. Re-render and commit them after any change that alters
the ground truth: scene, lights, materials, or the light transport itself.

Single frames differ by about ±0.1–0.2 dB from run to run (and a few pixels of the upscaled frames aren't
deterministic), so treat smaller differences as noise. Timings swing by 0.1–0.4 ms between launches; compare
alternating A/B runs.
