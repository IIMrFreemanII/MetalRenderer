---
name: feedback-no-stress-references
description: "The old stress hall stayed out of the dataset (slow references); main's new stress building is in, 4 zones x 8 frames"
metadata:
  type: feedback
---

On 2026-10-05 the user kept the old stress hall (floating cubes and drifting lights) out of the neural denoiser's
dataset: its references were by far the slowest. Main then replaced it with a stress building (Scene+Stress.swift:
warehouse, factory, garage, office; 400 props, 32 lights). The user chose to include that one, sized like the
showcase: 4 clips, one starting in each zone (`DatasetSpec.stressViews`), 8 frames each (`stressframes=`).
A reference of it took ~6.5 min on the M1 Max (32 lights traced at every bounce), against ~70 s for most scenes.

**Why:** reference time is the dataset's bottleneck; the user trades frames per clip for variety.
**How to apply:** time one reference of any new scene before adding it (`make-dataset.sh -d <scratch>` with a 1-clip,
1-frame `METALRENDERER_DATASET`), and ask when it's well above ~70 s. See [[neural-denoiser-status-2026-10]].
