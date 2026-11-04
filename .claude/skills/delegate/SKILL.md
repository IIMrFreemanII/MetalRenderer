---
name: delegate
description: Plan non-trivial work in the main (Opus) session and hand its implementation to cheaper, faster agents - `implementer-fast` (Haiku) for mechanical steps, `implementer` (Sonnet) for ordinary code - keeping shaders, hot loops, scene switching and cross-module design for Opus; then review each step's diff, send fixes back, and finish the checks. Use whenever asked to implement, build, add, change, port or fix something in MetalRenderer that is more than a small edit, even if delegation isn't mentioned. Not for questions, reviews, diagnosis or one-file small edits.
---

# Opus plans, cheaper models implement

The main session designs the change and reviews it; implementer agents write most of the code. Plan once, at the
session's effort, then let Haiku and Sonnet do the typing.

## 1. Plan, or do it yourself

Do it yourself, without a plan file, when the work is a handful of tool calls or a small edit to one file. When the
cause of a bug isn't known yet, diagnose it yourself first; delegate the fix once you know it.

Everything else gets a plan.

## 2. Write the plan

Write it to `.claude/plans/<slug>.md` (ignored by Git), after reading the code and the skills the work falls under
(`data-oriented` for a new feature, `scene-switching`, `metal-shaders`, `performance`). It has:

* **Context** - why, and what done looks like.
* **Design** - the types, signatures and data layout, and where each piece goes (CLAUDE.md, "Source layout"). Pin the
  interfaces between steps down here, so that steps running at the same time can't disagree.
* **Steps**, numbered. Each has:
  * **tier** - `haiku`, `sonnet` or `opus` (below);
  * **files** - the files the step owns; no two steps that may run at once own the same file;
  * **depends on** - the steps it needs first, or none;
  * **brief** - what to write, the exact names and signatures, an example to copy if there is one, the skills to
    follow;
  * **acceptance** - the build, which test suites, the shader check, an offscreen image: whatever proves it.
* **Status** - a line per step, updated as they land.

## 3. Tiers

| Tier | Who | For |
|---|---|---|
| `haiku` | `implementer-fast` | renames; wiring a registration (settings table, `GameScenes.scenes()`, the benchmark registry); boilerplate copied from a named example; docs and comments; test scaffolding from a spec |
| `sonnet` | `implementer` | plain-Swift features with the signatures given; editor and panel UI; tests; Python tools |
| `opus` | the main session | Metal kernels and the `GPUTypes.swift` / `Types.metal` layout; per-frame hot loops (`data-oriented`, `performance`); scene loads, switches and GPU order (`scene-switching`); APIs that cross modules; anything the plan couldn't pin down |

When unsure between two tiers, take the higher one. A step that is mostly mechanical with one hard part is split:
the hard part is an `opus` step.

## 4. Dispatch

* One `Agent` call per step, `subagent_type: implementer` or `implementer-fast`. Their model and effort come from
  their definitions in `.claude/agents/`; don't pass `model` or `effort`.
* The prompt is the step's brief: the plan file's path, the step number and text, the files it owns, the acceptance
  check. The agent knows its standing rules (checks, never commit, report shape); don't repeat them.
* Steps with no dependency between them and no file in common go out **in one message**, so they run in parallel.
  The rest go out in order, once what they depend on has passed review.
* Your own `opus` steps run while the agents work, on files no running agent owns.

## 5. Review each step

When an agent reports:

1. Read `git diff -- <its files>` against the plan's design and the brief: names, signatures, layout, where the code
   went, nothing outside its files (`git status`).
2. Check that the commands it reports were the acceptance check and passed. Rerun one yourself when the report is
   vague or the step is risky.
3. If something is wrong, send the problems to **the same agent** with `SendMessage` (it keeps its context), as a
   short list of what to change. At most **2 rounds**; after that, fix it yourself.
4. Mark the step done in the plan's status, and dispatch what was waiting on it.

An agent that stops with a question: answer it with `SendMessage`, or fix the plan and send the new brief.

## 6. Finish

Once every step is done:

* Run the checks across the whole change: the related tests (`tests` skill), the shader check if a `.metal` file
  changed, `.claude/skills/scene-switching/scripts/switches.py` if a scene or a scene load changed, an offscreen
  image for a visual change, `Tools/modules/imports.py --check`, and `graphify update .`.
* Update the plan's status.
* Commit only when the user asks. Implementers never commit.

Tell the user which steps went to which tier and what review sent back, in a line or two.
