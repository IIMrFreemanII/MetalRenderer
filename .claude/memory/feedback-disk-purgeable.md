---
name: feedback-disk-purgeable
description: "df's free space is not the limit on the user's Macs: Finder counts purgeable space macOS frees on write"
metadata:
  type: feedback
---

Before saying the disk is too full, check the space Finder reports: `URLResourceValues.volumeAvailableCapacityForImportantUsage`
(a one-line Swift script), not just `df`. On 2026-10-05 `df` showed 13 GB free on the M1 Max while Finder showed
324 GB: the rest was purgeable (caches, iCloud copies, update snapshots) and macOS frees it as files are written.
The user wants as much disk used as training needs. Still report write failures loudly (the dataset writer prints
`dataset: can't write …`).

**Why:** the user corrected a too-small dataset plan ("my laptop has more free space than you have, use it").
**How to apply:** size datasets by the important-usage figure; keep a few GB of real margin; put big data in the
repo's gitignored `dataset/` so the user can look at it.
