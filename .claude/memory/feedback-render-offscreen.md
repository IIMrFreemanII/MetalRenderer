---
name: feedback-render-offscreen
description: "In MetalGI every render run Claude makes must be offscreen (no window, no focus steal); use the project's offscreen skill"
metadata:
  type: feedback
---

Render offscreen only: `METALRENDERER_BENCH` runs are headless since 2026-10-03, so use the `offscreen` skill (`render.sh`, `shot` mode). Never launch the app without `METALRENDERER_BENCH`, or with `METALRENDERER_WINDOW=1`, unless the user asks.

**Why:** the user keeps working on the same laptop while Claude iterates; windows that pop up and `NSApp.activate` stole their focus.
**How to apply:** for anything that truly needs the interactive window (input, panels, windowed launch time), ask first. Trap found while building it: MTKView hands out `currentDrawable` only inside its own `draw()`, so a windowed loop must call `view.draw()`, not the renderer directly. See [[feedback-measure-baseline-copy]].
