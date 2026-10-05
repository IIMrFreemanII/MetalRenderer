---
name: feedback-related-tests-only
description: "While developing, run only the test suites related to the change, never the whole swift test suite unless asked"
metadata:
  type: feedback
---

Run only the test suites that cover the files a change touched. Use `.claude/skills/tests/scripts/related.sh` (the
project's `tests` skill). Never run a bare `swift test` while developing. The full suite runs only when the user asks.

**Why:** the user said running the whole suite for every feature slows development down. The full run takes about
40 s, mostly in KernelVariantsTests' GPU compiles.

**How to apply:** after editing, run the `tests` skill's `related.sh`. A change no suite covers is proven with images
instead (see [[feedback-render-offscreen]]).
