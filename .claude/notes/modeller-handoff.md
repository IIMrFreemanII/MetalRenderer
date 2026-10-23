# Modeller: handoff

Branch `claude/3d-modeling-mesh-sculpting-cfdc7e`. Built on the M1 Max, 2026-10-23. README "The Modeller" says what it
is; this note says where things are, what was checked and what is left.

## Where things are
- `Sources/Modeling` (new module, on EngineCore and Materials):
  - `Mesh/`: `EditMesh` (Blender's Mesh layout, `Draft` remakes it), `MeshTopology` (CSR tables, `validate`),
    `MeshNormals` (triangulation, corner normals with sharp edges, `TriangleMesh`), `Selection`, `Primitives`.
  - `Ops/`: delete/dissolve, extrude/inset, loops/rings/loop cut, bevel (edges, vertices, segments), merge, fill,
    connect, subdivide, normals, triangulate/tris to quads, duplicate/separate/join/split, marks, knife (points
    inside faces, cuts ending inside one go on to its nearest corner), `EdgeSlide` (SlideOps), bridge edge loops
    (BridgeOps: same counts quads, else a zipper of triangles), spin (SpinOps).
  - `Transform/`: `TransformOperation` (G/R/S, constraints, typed values, snap), proportional weights, `BlenderAxes`.
  - `Modifiers/`: `Modifier`, `ModifierStack` + `ModifierCache` (per-stage cache), `ModifierOps`, `CatmullClark`,
    `BooleanOps` (BSP exact, voxel).
  - `Sculpt/`: `SculptMesh` (leaf-ordered tree), `SculptBrush` (kernels), `SculptStroke` (dabs, symmetry, undo
    records), `Multires`/`MultiresData`, `DynTopo` + `SculptLayout` (its in-place edits of the layout, its undo),
    `TriangleTree` + `VoxelRemesh`.
  - `UV/UVOps`: unwrap by seams / smart project on the painter's `UVUnwrap.flatten` and `UVPack` (made `package`).
  - `IO/`: OBJ, glTF in/out, `ModelAsset` (section file `modelasset/1`), `ModelStore`.
  - `Viewport/` + `Shaders/Viewport.metal`: the raster viewport, picking (`pick`, `pickRegion`), `SculptDrawing`.
- `Sources/Editors/Modeling`: `ModelingPanel` (window), `ModelingModel` (+Input, +Actions, +Files, +Panels, +Gizmo,
  +Sculpt), `ModelingKeymap`, `ModalOperators`, `SculptController`, `StageRenderer` (Rendered), the views
  (`ModelingView`, `ModelingSidebar`, `BlenderTheme`, `ModelingViewportView`). Host: `RendererController` (bottom of
  its file). App: Shift-M (RendererController.keyDown), Shift-Cmd-L and "Edit Mesh in Modeller" (App.swift).
- `Sources/MetalRenderer/Modeling`: `Scene+ModelAsset` (`mesh:<slug>` in `Scene.place`, the selection as a document),
  `Renderer+Modeling` (selection, saved-asset pickup), `Scene+ModelingStage` (`.modelingStage`, `ModelingStage`).

## Verified
- Tests (dev build): ModelingMesh, IO, Ops, Transform, Modifier, Sculpt, Viewport, Editor — all green. The editor
  tests drive the window's model by keys and clicks through the real picking pass (Tab, A, click/box select, E with a
  typed value, G/R/S on Blender's axes, Shift-A, X menus, Ctrl-R slide, I, a sculpt stroke and its undo, save/open).
- Pictures (`MODELING_PNG=<folder>` with ModelingViewportTests / ModelingEditorTests): object, edit (vertex, edge,
  face, x-ray), top orthographic, the whole window in Layout, Modeling and Sculpting.
- Sculpt timing, release, M1 Max (`MODELING_PERF=1 Tools/release.sh test --filter ModelingSculptPerfTests`), 2.0M
  triangles: see the README section's numbers (dabs ~1 ms, tree build ~0.4 s, viewport frame at 2880×1800 ~11 ms with
  its readback).

- Scripted, headless (`ScriptModeller`, the socket's `modeller`, MCP `modeller`, `Tools/script.py --modeller`,
  `run.modeller`; README "Scripts", "The Modeller, scripted"): `Scripts/modeller-tour.swift <folder>` passes every check
  in a `METALRENDERER_BENCH=serve` app (extrude, loop cut, GG slide, bridge, spin with a typed angle, F3 inset, a knife
  cut ending in a face, a sculpt stroke and its undo) and writes the window after each and a Rendered picture (the
  head path traced on the stage, from the Modeller's view). Save + place put `mesh:<slug>` in the app's scene.
  Found and fixed that way: the stage renderer took the main view's saved settings (a Solid view showed in Rendered
  mode) and its first scene reset the camera to the stage's default; it also ran a headless app's benchmark
  (`Renderer(benchmarked: false)` now).

## Not done / next
- The window itself was never shown or clicked by hand (the rule: no window unasked). A hand test is due: trackpad
  orbit, pen pressure, popup menus' placement, the N panel's fields, Rendered mode's layer. What a script can reach
  (keys, clicks, operators, popups' items, the window's picture, the Rendered frame) is checked headless by the tour;
  what it can't is AppKit's own: real events, the menus as NSMenus, the search field's focus, the layer's resizing.
- Rendered mode: a second `Renderer` on a `LayerSurface`; built and wired, not run in a window. It remakes its scene
  on every change (a moment after it); a refit path for sculpt strokes would be faster on big meshes.
- Dynamic topology is local (`DynTopo`, `SculptLayout.swift`): leaves have room to grow, move to the end of the
  arrays when they outgrow it, split past twice the leaf size; a stroke's undo keeps only the leaves it changed
  (`SculptLayoutUndo`); `compact()` packs what moves left behind at a stroke's start. Per mouse event at 2M triangles
  (release, M1 Max): ~2 ms with a brush 6× the detail, ~6.5 ms at 20×, ~23 ms at 48× — the same as on a 127k mesh
  (`ModelingSculptPerfTests.testDynamicTopologyTwoMillion`, `ModelingDynTopoTests` for the layout's consistency and
  undo). Collapses are below 2/5 of the split length (Blender's ratio; 4/5 made splits and collapses undo each other).
  Not done: leaves that shrink aren't merged (many collapses leave small leaves); the detail is per mouse event, not
  per dab; a stroke's first event moves the untouched leaves it meets (up to ~18 ms at 20×); packing is ~100 ms at 2M.
- Mirror's clipping and bisect, bevel's patches with segments > 1 at corners (an n-gon, not a grid) — not there.
  Edge slide has no Even (E) or Flip (F); bridge has no cuts, twist or merge options (no redo panel to set them);
  spin has no Dupli; F3 lists menu operators only (not panel settings). Edge slide's GG, Shift-V, spin and the F3
  popup (`OperatorSearch.swift`, an NSTextField for its keys) are tested headless, not clicked in the window.
- Builder-made objects: saving places the model where they stand, but the builder's original stays.
- `SceneKind.modelingStage` is a scene of its own; the settings panel may list it.
- M4 Max: time the same perf test; Metal 4 untested.
