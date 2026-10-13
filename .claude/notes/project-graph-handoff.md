# Project Graph: handoff

Branch `claude/project-graph-editor-ca9826`. A window for finding your way around the project: the scenes, what each
is made of, and the assets they share, drawn as a graph. Key **Y**, or **⇧⌘G** in the app menu.

## What it is

- **Outlines** (`ProjectGraph/Scene+Outline.swift`, `SceneOutline.swift`)
  - `Scene.makeOutline()` turns a scene into a tree.
  - The builders' objects come first: `Scene.object("Room/Floor") { … }` and `beginObject` / `endObject`, which nest.
    Then labels: `label(mesh:)`, `label(assembly:)`, `label(sdf:)`.
  - Everything else is grouped by system (Plants, Buildings, Lights, Physics, …), then by what it is an instance of.
  - More than 24 instances of one thing become one *aggregate* node, whose members are paged in the window.
  - Ids are stable while the builder doesn't change.
  - Tagged so far: the Cornell room, the gallery, physics, city lots (with their style), forest species, and every
    glTF model (in `addModel`). Other scenes fall back to auto-groups.
- **Outline files** (`OutlineStore`)
  - Each installed scene writes `Assets/Scenes/Outlines/<scene>.json`, so the graph knows scenes that aren't loaded.
  - `METALRENDERER_BENCH=outlines` makes every scene once, headless (about 3 minutes on the M1 Max), and writes them all.
- **Edits** (`SceneOverrides.swift`)
  - Saved as `Assets/Scenes/Overrides/<kind>.json`, keyed by outline id plus fingerprint.
  - Hide and duplicate change the scene: they are the registry key `SceneSettings.sceneOverrides`, and the scene is
    made again.
  - Rename, folders and pins change only the graph.
  - Hidden instances keep their index: they get mask 0 and are shrunk to nothing. Hidden lights are taken out.
  - Copies are appended at the end.
  - Bodies, particles, deforming and walking things are locked.
- **The graph** (`ProjectGraph.swift`)
  - Merges the outlines with the project's library (species, styles, characters, VFX and material graphs).
  - Each asset is one node: generators always, meshes and materials only when two or more things share them.
  - Source files come from graphify's `graph.json`: the builder, and what it calls.
  - `visible(open:)` returns the part under the open nodes. Edges into closed branches end at the branch.
- **Layouts** (`GraphLayout.swift`): force (Barnes–Hut; dragged nodes are pinned), radial, tidy tree, and a 3D cone
  tree.
- **Window** (`ProjectGraphEditor/`): the outliner (drag a row onto another to move it), the graph, the inspector,
  search, Pick (click in the view to select), and Show in Viewport (the camera flies there; another scene loads first).
  - Double-click opens the asset's editor.
  - The cone view is its own Metal view, `ConeTreeView.swift`, with inline shaders.

## Checked

- `ProjectGraphTests` (31 tests): outlines, overrides, merge, search, sources, layouts, the model with a stand-in host,
  undo, saving.
- `PROJECT_GRAPH_PNG=<folder>` draws the window offscreen, and the cone into a texture.
- The related suites pass.

## Not checked (needs the app, by hand)

- The window itself: keys, drags, the outliner's drag and drop, the cone view's orbit, Pick, the fly-to and its
  selection box (`Renderer.frame`, `selectionSegments`).
- Opening each editor from a double-click.
- Hiding or duplicating in a big scene (the scene is made again).
- The M4 Max and Metal 4.

## Next

- Tag more builders where the auto-groups read poorly (stress, market, crowd, mireland, showcase).
- The tree layout is very wide when many nodes are open. A left-to-right tree, or framing the selection, would help.
- Reparenting is folders only (as decided). Real transform parenting would need a parent pass when edits are applied.
