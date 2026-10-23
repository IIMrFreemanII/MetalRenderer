---
name: app-control
description: Drive a running MetalRenderer app without relaunching it - place, move or remove objects, set the camera, switch scenes, change settings, run Swift scripts against the live engine, read its state and capture frames - through the metalrenderer MCP tools or Tools/script.py; and drive the Modeller headless (keys, clicks, sculpt strokes, operators, its pictures) through the modeller tool. Use whenever you would change a scene or the app's state to try, check or show something, build a test setup or a scene step by step, reproduce a bug at a pose, or A/B a setting, and whenever you choose between a typed tool and a Swift script. Also use when the same small script keeps being written: it says when and how to promote it to a typed tool.
---

# Driving a running app

The app takes requests through its script socket (README, "Scripts"). The `metalrenderer` MCP server (`.mcp.json`,
`Tools/mcp/metalrenderer.py`) and `Tools/script.py` both use it. Two kinds of request:

* **Typed tools:** small fixed edits with a JSON schema, done at once with no compile, which can't crash the app:
  `place_object`, `move_object`, `remove_objects`, `set_camera`, `switch_scene`, `set_settings`, plus `scene_state`
  and `capture` for reading; `modeller` for the Modeller (steps, then its state and a picture).
* **Swift scripts** (`run_swift`, `Tools/script.py <file>` or `-e`): any code against the engine's `package` API,
  compiled against the running binary (about 0.5 s, 4 s with a cold cache).

## Rules

1. **Never open the window.** Use the user's running app if there is one (`scene_state` answers), otherwise a
   headless one: MCP `start_headless`, or `Tools/script.py --serve`. From a Bash tool call, start it with
   `run_in_background` instead (`METALRENDERER_BENCH=serve .build/release/MetalRenderer`): the harness kills the
   children of a finished call. Quit it when done (`quit_headless`, `Tools/script.py --quit`). Never quit the user's
   window app.
2. **A typed tool when one fits, a script when it doesn't:**

   | What you want | Use |
   |---|---|
   | One object placed, replaced (same name), moved, turned, scaled or removed | `place_object`, `move_object`, `remove_objects` |
   | The camera somewhere, looking at something | `set_camera` (`lookAt`, or yaw and pitch in degrees) |
   | Another scene | `switch_scene` |
   | Settings by their names (`view solid=1`, `gi …`) | `set_settings` (`scene_state` lists the lists and keys) |
   | What is loaded, where things are | `scene_state` |
   | To see it | `capture` (a scale of 0.5 is plenty), or `run_swift` with `capture: true` |
   | Many objects, loops, a layout computed from numbers, steps with waits in between, motion every frame, anything in the engine no tool covers (lights, buildings, plants, terrain, physics, materials) | `run_swift` |
   | The Modeller: keys, clicks, drags, sculpt strokes, operators by name, popups, F3, Rendered mode, its state and pictures (viewport, window, rendered) | `modeller` (`Tools/script.py --modeller`), or `run.modeller` in a full-form script for checks in a loop (`Scripts/modeller-tour.swift`) |

   Several typed calls in a row for what one loop would do is the sign to write a script instead. The `modeller` tool
   drives a Modeller of the app's own, offscreen; never the user's Modeller window. Click with `{"world": [x, y, z]}`
   when you know where a thing is, not with guessed pixels; after a step, read the state's counts and look at a
   `window` picture. Start a headless app for it with `METALRENDERER_MODELS=<scratch folder>` so saved models stay out of
   `Assets/Models`, and remove what `place` wrote to `Assets/Scenes`.
3. **See before you claim.** After a change, `capture` and look at the PNG (Read), or check `scene_state`. Say what
   you saw.
4. **Scripts:** the short form for one-off statements; the full form (`func run(_ run: ScriptRun)`) when it waits
   (`run.waitForScene()`, `run.wait(frames:)`) or moves things every frame (`run.onFrame`). Change what a scene has
   with `renderer.editPlaced { file in … }`. Name what a script places with a prefix of its own and remove that prefix
   first, so a rerun replaces it instead of piling up. A script worth keeping goes into `Scripts/`, with a header
   comment saying what it does and how to run it; a throwaway one goes through `-e` or `code`.
5. **A trap in a script takes the app down** (an index out of range, a force unwrap, `fatalError`). Guard and use
   `run.fail("…")` instead. If the user's window app is the target, be careful: a crash loses their session.
6. **Clean up what you changed.** Placing writes `Assets/Scenes/<scene>.scene`, a file in the repo. When the edits
   were only to try something, put the file back (`git checkout -- Assets/Scenes/<scene>.scene`, or delete it if it
   is new) unless the user wants to keep it. Put settings back in the user's app.
7. **After a build, relaunch.** Scripts compile against the running binary; the app refuses with "relaunch" until
   then. Typed tools keep working.

## Promoting a script to a typed tool

**When.** The same shape of script (the same engine calls, only the values differ) has been written about three
times, in this session or in `Scripts/`, or the user keeps asking for that action. It must also be:

* a single plain edit of the scene's file, the camera or the settings;
* without loops, waits or per-frame work;
* describable by a few JSON fields of plain numbers and strings.

Don't promote one-off or creative work, procedural layouts, or anything whose arguments would be engine types.

**Ask first.** Promoting adds to the app's interface, so propose it to the user in one line (what the tool would be
and which repeated scripts it replaces). Just do it when the user asked for that tool.

**How:**

1. **The engine.** Add a case to `SceneCommand` (`Sources/MetalRenderer/Scripting/SceneCommand.swift`): add its key
   to `keys`, decode it in `decode` (check every field, and give an error that says what to send), and apply it in
   `apply(to:)` on the render thread through the same engine path a script would use (`editPlaced`,
   `renderer.camera`, `renderer.settings`), never a second one. Keep pure edits on `SceneFile` (as `upsert` and
   `removeObjects` are), so the tests reach them without a renderer. The socket answers once the scene the command
   asked for is in.
2. **The tests.** In `Tests/MetalRendererTests/Scripting/ScriptingTests.swift`: the decode of a good request and of
   bad ones, and the pure edit. Run them with the `tests` skill.
3. **The tool.** In `Tools/mcp/metalrenderer.py`, add a `TOOLS` entry (a description that says when to use it, and
   a schema with units and the axis convention: y up, degrees) and its key in `COMMANDS`. Name it in `run_swift`'s
   description, which sends single edits to the typed tools. `client.command` and `Tools/script.py --send` need no
   change.
4. **The docs.** The README's "Scripts" section (the tools' list) and this skill's table above.
5. **Proof.** Build release, start a headless app, call the new tool, `capture`, look at the PNG, and run the
   failure case once (a wrong field: a clear error, the app still up).

## Reference

* Socket requests: `{"path": …, "args": […]}`, `{"state": true}`, `{"capture": "<png>", "scale": s}`,
  `{"place"|"move"|"remove"|"camera": {…}}`, `{"quit": true}`. Each is answered with JSON lines ending in
  `{"exit": n}` (0 done, 1 failed, 2 bad request or compile error).
* `Tools/script.py --send '{"move": {"name": "Crate", "position": [0, 1, 0]}}'` sends a typed command from a shell.
* The stage (`switch_scene` `stage`) is an empty floor with named materials (`scene_state` lists them under
  `namedMaterials`): the place to build test setups.
* The camera: yaw 0 looks down -Z, positive pitch looks up; positions are in metres, y up.
