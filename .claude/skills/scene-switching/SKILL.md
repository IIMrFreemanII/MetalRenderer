---
name: scene-switching
description: Keep switching scenes safe in MetalRenderer - no GPU timeouts, crashes or pictures of the scene before. Use when adding or changing a scene (GameScenes, a SceneDefinition or SceneBehaviour), a system a scene carries (physics, particles, water, terrain, crowds, cars, interiors), anything `install` or `createSceneResources` builds or resets, state on `Renderer` that names a scene's instances, lights or objects, a simulation's clock or steps, a scene load or remake (hot reload, placed files, settings), or GPU work around a load; and before calling such a change done. For a new feature's design use the data-oriented skill too; to drive a running app, the app-control skill.
---

# Scene switching

A scene is put in by `Renderer.install` (`MaterialGraph/Renderer+ProceduralMaterials.swift`): after a background load
(`startLoadingScene`, the app and a headless app serving scripts) or right away (`rebuildScene`, a benchmark's config).
Every install is one `SceneChange` (`Scene/SceneChange.swift`), and that alone decides what the new scene keeps:

| | `.switched` (another kind) | `.remade` (same kind made again: a setting, a hot reload, a placed file, a failed load) | `.continued` (the world's next tile, the city's next interior, a workshop's edit) |
|---|---|---|---|
| Clock (`setTime(0)`) | from zero | from zero | kept |
| Camera, orbit, walker | the scene's own | kept | kept (moved with the world) |
| GI history, upscaler, reference | reset | reset | kept |
| `SceneSession` | new | new, the scripts' closures kept | kept, but what names the instance table |
| ReSTIR reservoirs | reset | reset | reset when the light table may differ |
| `SceneBehaviour` | old `leaving`, new `entered` | the same | the same |

A benchmark's config sets its own camera and clock (`configured`), so its stills still replay to their time.

Each failure below happened, sometimes more than once, before the rule that prevents it existed.

## Rules

1. **Per-scene state lives on the `Scene` or its `SceneBehaviour`, and goes with it.** Renderer-side state that names
   the scene's instances, lights or file objects, or that was begun in it (a pick, a drag, a flight, a script's
   `onFrame`), goes in `SceneSession` (`Renderer/SceneSession.swift`), which `install` replaces by its change. Resources
   are made in `createSceneResources`. No statics: a static that must outlive scenes is reset in the behaviour's
   `entered`/`leaving`. (A pick or a placement drag begun in one scene used to land on object `k` of the next, and a
   script's closure indexed the next scene's instances.)
2. **A simulation counts from its scene's zero and never catches up in one frame.** New physics, particles or any
   stepped world start at step 0 against the scene's clock, which every switch and remake sets to 0. A frame takes at
   most `Renderer.stepsPerFrame` steps (20 in the app; a benchmark's config replays at once): a jump of the clock catches
   up over frames. A new stepped system takes its limit from the same place. (The renderer's clock ran on through
   switches and remakes, and the muscles' GPU soft bodies replayed minutes of steps in one command buffer, 3-8 s, past
   the watchdog: PR #133. The office tower's furniture did the same on the CPU: `cc28c203`.)
3. **A scene is known by `Scene.serial`, never by its address.** A new scene often gets the freed one's address
   (`ObjectIdentifier`), and the water and the sky kept the old scene's (`b9b83962`).
4. **A background load touches no live state.** `prepareScene` reads the `LoadOptions` snapshot and its own new
   scene, never `renderer.settings` or the scene being drawn (`7b6e4134`). Loads run one at a time on `sceneLoads`, each
   with a number (`SceneLoadQueue`): only the latest asked for is put in, a load the settings stopped asking for is
   dropped (a switch away and back while it loads), and a long load checks `LoadJob.isCancelled` between batches.
5. **No GPU work outside the frame's order.** Metal 4 work goes in the frame's encoders; what has no working Metal 4
   form goes in an interlude (`Metal4Frame.interlude`, on the interludes' own queue, after the Metal 4 work before it
   is done or has failed). Nothing commits to that queue beside the frame: MetalFX's Metal 4 scaler did, ungated, and
   timed out after switches (PR #129). Every resource a frame reaches is declared that frame (the residency set drops
   the rest: `10dba8ff`), and a replaced scene's resources leave it after `noteSceneChange`.
6. **A first frame stays under the watchdog.** What a new scene builds at once (structures, maps, the first steps)
   fits a frame or spreads over frames, as liquids' steps and the BLAS rebuilds do. An interlude now waits for a slow
   pass (up to 10 s: past it, it times out), and its queue is made again after one failed, but a pass of seconds is
   still a frozen app. Metal 4 kills no command buffer for running long: a 27 s one ran to its end.
7. **A new kind of reload names its `SceneChange`.** If it fits none of the three, add the case to `SceneChange` and
   to the table above, with what it keeps and why, and a test in `SceneSwitchTests`.

## Prove it: `scripts/switches.py`

```bash
Tools/build.sh   # scripts compile against the app: build it after the last source change
python3 .claude/skills/scene-switching/scripts/switches.py --saved
```
It starts its own headless app (no window, never the user's), with `METALRENDERER_RESIDENCY_LIFE=16`, runs
`Scripts/scene-switches.swift` through that app's socket, quits it and reads its log step by step:

| Step | What it does |
|---|---|
| `tour` | every scene once, 120 frames each (not the world and the city) |
| `pairs` | the heavy pairs back and forth: Fluids ↔ Muscles, Destruction (massive) → Cars → Stage, World ↔ City |
| `midload` | another scene asked for while one loads, then the one drawn: the loads dropped |
| `remake` | Muscles, Fluids, Soft bodies made again 15 s in (a hot reload's remake), Cars with another count |
| `jump` | the clock jumped to 60 s in four physics scenes: caught up over frames |
| `stale` | a paused scene pictured, then pictured again after a detour: the same picture (`STALE_DB`) |
| `slow` | (with `--env METALRENDERER_STEPS_PER_FRAME=500`) physics passes of about 3.7 s: the interludes wait for them |

A step fails on a Metal command buffer that failed, an interlude whose wait gave up, physics behind its clock (outside
`jump` and `slow`), a failed load, the script's `FAIL` lines, the app quitting, or a `stale` pair apart. `--saved` uses the window's
saved settings, where the GPU timeout of October 2026 showed and the defaults didn't; run both. Steps by name narrow
it (`switches.py remake jump`). A new scene goes in the tour by itself (`SceneRegistry.kinds`); one that is heavy or
has its own reloads gets a line in `pairs` or `remake`.

On the M4 Max the whole run takes about 6 minutes. Run it with `run_in_background`.

## Before calling a scene done
- Its state is on the scene, its behaviour or `SceneSession`; nothing of it in a static.
- Its simulations start at zero and take at most `stepsPerFrame` steps a frame.
- It is known by `serial`; its load reads only the snapshot.
- Its GPU work is in the frame or an interlude, every resource declared each frame.
- `switches.py` and `switches.py --saved` pass, with it in the tour; `related.sh` passes (`SceneSwitchTests`).
