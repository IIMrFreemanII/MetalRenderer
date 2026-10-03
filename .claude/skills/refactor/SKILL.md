---
name: refactor
description: Refactor and optimise MetalRenderer's code after a new feature - fold the new code into the project's structures (settings table, benchmark registry, frame plan, pipeline set, capabilities, the Metal 3 / Metal 4 encoders), remove what the feature duplicated or left behind, speed up what it put on a hot path, and prove the renderer still draws the same frames. Use once a feature works or is committed, and whenever asked to refactor, clean up, tidy, simplify, restructure, deduplicate, split a long function or file, or "optimise what I just added" in this repo, even if the word refactor isn't used. For speed work with no restructuring, use the performance skill.
---

# The pass after a feature

A feature lands as one large change that makes something work. This pass is the change after it: the same behaviour
in less code, in the place the project keeps that kind of code, at no extra cost per frame. The history has the
model for it: 9d3e661 (`draw()` split around a frame plan), 383c5fa (the settings table), 46765c1 (benchmark modes as
a registry). Read one with `git show -s <hash>` to see what a finished pass looks like.

Four rules:
* **A refactor is its own change.** It starts from the finished feature and is never mixed into it, so the feature's
  state can be the baseline everything is compared with.
* **Behaviour stays the same,** unless the change is listed under "Behaviour changes" with its reason.
* **"Unchanged" needs a proof:** identical images, identical settings, green tests, timings within noise. A claim
  without one is reported as not checked.
* **An optimisation is kept only with a number** (the `performance` skill's rule).

## The pass

1. **Scope.** The feature is the commit or range named in the request. With none, it is the branch's work plus
   anything uncommitted:
   ```bash
   git diff --stat $(git merge-base main HEAD)
   ```
   For one commit that is `git show --stat <commit>`, for a range `git diff --stat <a>..<b>`. Read the whole diff,
   not just the stat: new files whole, then one file at a time (`git diff <base> -- <file>`; Renderer.swift's diff
   alone can be a thousand lines). Then look at what the new code sits in: `graphify query` and `graphify path`
   (CLAUDE.md) show its callers and neighbours. Without `graphify-out/graph.json`, run `graphify update .` or use
   grep.

   The pass may change the new code, and the existing functions and types the feature added branches to, copied
   from or worked around. Old code that the feature only passed through is noted in the report and left alone, so
   the proof stays small enough to run.
2. **Freeze the baseline** before the first edit:
   ```bash
   .claude/skills/refactor/scripts/baseline.sh
   ```
   It copies the tree as it stands (uncommitted work included) into the worktree `../MetalGI-base` and builds it in
   release. `swift test` must be green before you start: a test that fails already isn't yours to explain later.
3. **Survey.** Go through "What to look for" with the diff open. Write the candidates as a short list, ranked by
   what each pays back (not by the order of the checklist): what, where (`File.swift:line`), what it removes or
   guards, and which proof covers it.
   * Include only what you read at the cited lines. A candidate that rests on a guess costs a build to disprove.
   * Speed ideas for step 5 go on the same list, marked "needs a number".
   * Where no proof exists (a comment, a window title, an error path no mode reaches), write "not checked" and keep
     the change small enough to verify by reading.
   * A bug or an inconsistency found in the feature is not a refactor. List it apart. Fixing it is a behaviour
     change, so it needs the user's word.

   Show the list to the user and carry on; they asked for the pass, not for a proposal. Stop and ask only when a
   candidate would change behaviour the user can see, or one of the things under "What stays fixed".
4. **Apply one candidate at a time.** After each one:
   ```bash
   swift test
   ```
   ```bash
   .claude/skills/refactor/scripts/same.sh quick
   ```
   and the modes that cover what the candidate touched ([references/proving.md](references/proving.md) has the
   table). `same.sh` builds the current tree, runs the mode on both binaries and compares the images. The runs are
   offscreen, like every benchmark run (the `offscreen` skill); never launch the binary without `METALRENDERER_BENCH`. When a proof
   fails, find out why before anything else: either the candidate changed behaviour (fix it or drop it), or the
   setting differs from run to run (`same.sh --self` tells). Never carry a failing proof into the next candidate:
   two changes later nobody can tell which one broke the image.
5. **Optimise what the feature put on a hot path:** a new pass, a new per-frame upload, a bigger kernel, a slower
   builder. Load the `performance` skill and follow its loop, with the baseline as side A:
   ```bash
   .claude/skills/performance/scripts/ab.sh -n 3 --bin-a ../MetalGI-base/.build/release/MetalRenderer -- METALRENDERER_BENCH=quick -- METALRENDERER_BENCH=quick
   ```
   Also run this once when the pass only restructured the frame path: "per-frame CPU and GPU time are unchanged" is
   a claim like any other. Keep what the medians support, revert the rest, and write down what didn't help.
6. **Close.**
   * Tests for any structure the pass introduced, in the way `Tests/MetalRendererTests` does it: a test that fails
     when the next feature forgets the structure (removing a setting's env name fails `SettingsTableTests`).
   * Docs that describe what moved: `README.md` (the file table under "How a frame works", the env variables), and
     the `performance` skill's references where they name a function or file that changed. Add a row to
     [references/structures.md](references/structures.md) when the pass created a structure.
   * `graphify update .` (CLAUDE.md), then `.claude/skills/refactor/scripts/baseline.sh --remove`.
   * Draft the commit message (below). Leave the work uncommitted unless asked to commit.

## What to look for

Roughly in order of how much each one pays back. [references/structures.md](references/structures.md) lists the
project's structures with the sign that a feature went around each.

* **New code outside a structure that exists for it.** A list of keys parsed by hand, a pipeline built at its use
  site, an `#available` check in the frame loop, a stage that reads `settings`. The feature worked around the structure, or the
  structure couldn't hold it yet; either way the fix is in the structure.
* **The second copy.** The same list, switch, parser or flag set written out again for the new case. Three similar
  `case`s with a new fourth are a table. A `Config(` literal repeated with one field changed is a modifier.
* **A function or file the feature pushed past what one can read.** `draw()` at 767 lines was the signal for the
  frame plan. Split along what the code decides (plan) and what it does (stages, encoding), not by line count.
* **State set in several places,** or a flag that mirrors something it could be derived from. One place sets it;
  everything else reads it.
* **What the feature left behind:** code its change made dead, parameters nobody passes any more, comments and
  README lines that describe the old behaviour, a temporary env variable or `print` from its debugging.
* **One API only.** A pass that encodes for Metal 3 and not through `ComputePass`, so Metal 4 lacks it.
* **Cost on the frame path:** allocations, string formatting or a new command buffer per frame; a full-screen pass
  that could be part of an existing kernel; a value stored that the next pass could compute. The `performance`
  skill's checklists are the reference.
* **A missing guard.** A struct shared with the shaders without its size assert on both sides, a new option without
  a test that it falls back or round-trips.

A candidate earns its place when it removes a second copy, a thing the next feature would have to remember, or
measured time. Renaming and moving code that leaves the same amount to read and to remember is not a candidate.

## What stays fixed

These are interfaces to things outside the code, so a refactor that changes one breaks something no test sees:
* `METALRENDERER_*` variable names and their keys: saved command lines, the README and Copy as Env output use them.
* Benchmark mode and setting names: they become PNG names that the `Tools/eval` scorers look up.
* `Tools/eval/refs`: re-rendered only when the ground truth changes, never for a refactor.
* The saved-settings format (`SettingsStore`): a renamed `RenderSettings` field drops the value the user had saved.
* Disk cache formats without a version bump (the `.metalrenderer-cache` folders next to the models).
* Swift↔MSL struct layouts (`validateGPULayouts` in GPUTypes.swift, `static_assert` in Shaders/*.metal).

## The report and the commit message

Report what was done, what was proven and how, what was tried and dropped, and what was seen and left alone. The
commit message has the same content in the project's form:

```
Area: what it is now; a second part if there is one

- File.swift: what changed, with the counts that show it (draw(): 767 lines -> 59; Config( literals: 108 -> 72).
- Tests: what they now guard.

Behaviour changes:
- Only if there are any, each with what the user sees.

The proof, as a paragraph: how many images from which modes are bit-identical with the previous build, what else
was compared (settings dumps, setting names), timings with the GPU and macOS version. What didn't help. Not run:
whatever could not be checked on this machine, and why.
```

Counts come from the tools (`wc -l`, `grep -c`, `same.sh`'s totals), not from memory.
