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
| `manylights.py` | `manylightsq`: stress-scene direct light at 32 / 128 / 1024 / 4096 lights, each direct-light method; `sampledcheck`: sampled lights vs every light traced, per light type (within the run) | `refs/manylights/` (every light traced up to 1024; sampled lights at 4096) |
| `lightlab.py` | `lightlab` and `lightlabq`: the Light lab's booths (bias, leaks, realtime quality; see below) | — (the run's own accumulated frames) |
| `noise.py` | `denoise` (references from `noise`) | `refs/noise/` (render once, see below) |
| `hwrt.py` | `hwrtq`: MetalFX's denoising scaler at 3×, final image, Cornell, stress hall and gallery (reflections) | `refs/hwrt/` (supersampled 1920×1200, path traced) |
| `frost.py` | `frost`: the Material lobes scene's frosted sphere, still, after a camera move and raw: grain, flicker and error (within the run) | — (the run's own path-traced frame) |
| `pngdiff.py` | any two runs: per-image differences (did a refactor change the frames?) | — |
| `columns.py` | pipe a benchmark table in to pull out named columns | — |

Each mode's "ref …" settings render the references; once they exist, skip them with `METALRENDERER_GI_REFS=0`. When a run
does render them, the scorer copies them into `refs/<mode>/`. Re-render and commit them after any change that alters
the ground truth: scene, lights, materials, or the light transport itself.

Single frames differ by about ±0.1–0.2 dB from run to run (and a few pixels of the upscaled frames aren't
deterministic), so treat smaller differences as noise. Timings swing by 0.1–0.4 ms between launches; compare
alternating A/B runs.

## The Light lab: `lightlab.py`

Two modes over the lab's booths (`Sources/Game/Benchmark/Benchmark+LightLab.swift`), scored by one script that takes the
run folder(s) of either or both (`python3 Tools/eval/lightlab.py <run> [<run>]`, best with
`~/.venvs/metalrenderer-eval/bin/python`). It needs no `refs/`: each booth renders its own references into the run.
Settings are named `lab<NN> <group> <what>` (group: `types`, `shadows`, `materials`, `counts`, `yard`, `gi`).

* `lightlab` (bias and leaks): every booth with a direct check, built alone at its bookmark, GI off, constant sky, 1024
  frames accumulated at 0.75x: every light traced (`exact`), `sampled`, `megalights`, and `exact full`, the same booth in
  the full hall. Table: PSNR and mean ratio of Sampled and MegaLights against exact (the ratio should be 1.00), and the
  leak, mean |alone - full| / mean, flagged above 0.5%.
* `lightlabq` (realtime): every booth at its bookmark in the full hall at 0.5x, against a 2048-frame exact reference. MegaLights
  and Sampled, each under MetalFX (3x, box-filtered to 640x400 for scoring) and SVGF (no upscaling): a still at t = 5 s
  with the frame before it (flicker) and a one-second camera dolly ending at the bookmark, still moving. The motion booths
  (21, 22) have their motion on and a `moving` frame too. Booths with a specular check also get the PSNR over the
  brightest 2% of the reference's pixels. Booths with a GI check also get MegaLights + cascades GI under MetalFX against a
  1024-frame path-traced frame (`gi` table).
* The contact sheet `lightlab-contact.png` is written into the first run folder: each booth's MegaLights frame with its
  number, name and key scores.

Run one booth or group with `METALRENDERER_BENCH_ONLY` (substrings of setting names, separated by `|`):
`METALRENDERER_BENCH_ONLY=lab09`, `lab07|lab09`, `shadows`, `counts` (not `gi`: it also matches `megalights gi`, use `lab26`).
`lightlab` takes about 12 s per booth and `lightlabq` 20 to 40 s on an M4 Max (dev build).
