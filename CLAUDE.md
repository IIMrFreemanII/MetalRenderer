## Rendering runs

Check rendering offscreen with the `offscreen` skill (`.claude/skills/offscreen`). Benchmark runs (`METALRENDERER_BENCH`) have no window and don't take the focus. Never launch the app without `METALRENDERER_BENCH`, or with `METALRENDERER_WINDOW=1`, unless the user asks: they work on this Mac while you iterate.

## Driving a running app

Change a running app's scene and state with the `app-control` skill (`.claude/skills/app-control`): typed tools
(`place_object`, `move_object`, `remove_objects`, `set_camera`, …) for single edits, Swift scripts for the rest, both
through the `metalrenderer` MCP server (`.mcp.json`) or `Tools/script.py`; a script written again and again becomes a
typed tool. Never in the user's window unasked: a headless app (`METALRENDERER_BENCH=serve`), quit when done.

## Source layout

The code is in modules (README, "Source layout"): `Sources/EngineCore` (what every module shares, knowing no scene or
renderer); the systems `Sources/Plants`, `Physics`, `Characters`, `Effects`, `Materials`, `Buildings`, `Landscape`;
`Sources/MetalRenderer` (the engine: the scene, the renderer, and each system's part of them); `Sources/Editors` (the
window, the panels, every editor's UI); and `Sources/Game` (the demo scenes, their looks and benchmark modes). Each is
in a folder per feature: a system's data and algorithms in its module, what touches `Scene`, `Renderer` or
`SceneBuffers` (a `Scene+Feature.swift`, a `Renderer+Feature.swift`) in the engine's folder of that feature, an
editor's UI in the editors', a demo scene's builder in the game (registered in `GameScenes.scenes()`), a test in the
matching folder of `Tests/MetalRendererTests`. The engine never names a game scene (it asks the scene's
`SceneDefinition`) and never calls an editor. A per-element helper a frame's loop calls from another module is an
`@inlinable package` free function on plain types (`Tools/perf/hotcalls.py` finds the ones that aren't); build release
with `Tools/release.sh`, which rebuilds the modules above an `@inlinable` body that changed; keep each module's imports
to its dependencies (`Tools/modules/imports.py --check`). Find the package's files with `SourceTree`, never by counting
folders up from `#filePath`. The dev build hot-reloads saved shaders, `Sources/Game` and the scene's files (README, "Hot
reload"; `DevReload`): the engine reaches the game only through what `GameScenes.register()` registers, so keep it that
way, or a game reload can't replace it.

## New features

Plan and build them with the `data-oriented` skill (`.claude/skills/data-oriented`): what runs every frame over many
things is written in the fast subset of Swift and proven with a profile and `Tools/perf/hotcalls.py`; the rest stays
plain Swift.

## Scenes and switching

A new scene, a system a scene carries, or anything a scene load builds or resets follows the `scene-switching` skill
(`.claude/skills/scene-switching`): per-scene state on the scene or `SceneSession`, simulations from the scene's zero,
GPU work in the frame's order, and `scripts/switches.py` passing before it is done.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- graphify-out/ is committed, so a checkout has the graph as of its last commit; refresh it with `graphify update .` on a branch whose code has moved. When graphify-out/graph.json is missing, build it with the `code-graph` skill (`.claude/skills/code-graph/scripts/ensure-graph.sh`, which runs `graphify update .`), then query. Don't skip the graph for grep.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

## Handoff notes

Status and next steps of work moved between Macs are in `.claude/notes/` (for example
`metal-tracer-handoff.md`: the Metal-only tracer, to continue on the M4 Max; `terrain-editor-handoff.md` and
`water-handoff.md` for this branch's terrain and water). Read the one for your branch first.
