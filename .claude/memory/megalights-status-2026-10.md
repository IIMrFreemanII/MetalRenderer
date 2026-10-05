---
name: megalights-status-2026-10
description: "MegaLights direct-light mode (Oct 2026): what's built, measured results vs ReSTIR, what's left (half-res, faster tree walks)"
metadata:
  type: project
---

`DirectLightMode.megalights` (Shaders/MegaLights.metal, LightTree.swift) was committed on branch
claude/restir-replacement-options-c1b9e6 on 2026-10-04 as an optional mode; `auto` still picks ReSTIR above 256 lights.
Built: 16x16 tile light culling (reach from an exposure-relative cutoff), list samples + light-tree far-field samples,
"partition" (list owns listed lights in reach, tree the rest; MIS via partition=0), guiding hash, SVGF. Full res only.

Measured on the M1 Max (restirq, direct light): beats ReSTIR on quality at 32–4096 lights (e.g. 4096: 34.41/32.39 dB
static/moving with tree=3 vs 34.22/31.57); flicker still ~2x ReSTIR's. Unbiased (restircheck mean 1.00 everywhere).
Cost: much cheaper below ~64 lights, but 2–4 ms slower than ReSTIR's pass at 256+ lights (tree walks are
latency-bound: ~14 dependent node loads per sample).

**Why:** the user stopped after the light tree; the cost gap is the open problem.
**How to apply:** next steps if resumed are phase 3 (half-res sampling + 2x2 neighbour resolve) and a 4-wide tree with
adjacent siblings / lockstep walks. A global light-table sample as the far field was tried and lost 2.7–4.4 dB at 1024+
lights; cutoff and guiding sweeps didn't help. Plan: `.claude/memory/plans/megalights.md`.
Related: [[dev-macs]], [[feedback-render-offscreen]].
