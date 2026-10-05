---
name: feedback-no-stress-references
description: "Don't render references of the stress hall for the neural denoiser's dataset"
metadata:
  type: feedback
---

Keep the stress hall (`SceneKind.stress`) out of the dataset: no references of it. It is out of
`DatasetSpec.scenes`' default and `make-dataset.sh`'s list; train with `--exclude stress`.

**Why:** the user said so on 2026-10-05, after its references were by far the slowest of any scene (minutes each
against ~70 s for the others on the M1 Max).
**How to apply:** when adding scenes or clips to the dataset, never add the stress hall back; prefer cheap scenes
and random rooms for variety. See [[neural-denoiser-status-2026-10]].
