# Modeller: handoff

Branch `claude/3d-modeling-mesh-sculpting-cfdc7e`. Built on the M1 Max, 2026-10-23. README "The Modeller" says what it
is; this note says where things are, what was checked and what is left.

## Where things are
- `Sources/Modeling` (new module, on EngineCore and Materials):
  - `Mesh/`: `EditMesh` (Blender's Mesh layout, `Draft` remakes it), `MeshTopology` (CSR tables, `validate`),
    `MeshNormals` (triangulation, corner normals with sharp edges, `TriangleMesh`), `Selection`, `Primitives`.
  - `Ops/`: delete/dissolve, extrude/inset, loops/rings/loop cut, bevel (edges, vertices, segments), merge, fill,
    connect, subdivide, normals, triangulate/tris to quads, duplicate/separate/join/split, marks, knife.
  - `Transform/`: `TransformOperation` (G/R/S, constraints, typed values, snap), proportional weights, `BlenderAxes`.
  - `Modifiers/`: `Modifier`, `ModifierStack` + `ModifierCache` (per-stage cache), `ModifierOps`, `CatmullClark`,
    `BooleanOps` (BSP exact, voxel).
  - `Sculpt/`: `SculptMesh` (leaf-ordered tree), `SculptBrush` (kernels), `SculptStroke` (dabs, symmetry, undo
    records), `Multires`/`MultiresData`, `DynTopo`, `TriangleTree` + `VoxelRemesh`.
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

## Not done / next
- The window itself was never shown or clicked by hand (the rule: no window unasked). A hand test is due: trackpad
  orbit, pen pressure, popup menus' placement, the N panel's fields, Rendered mode's layer and camera.
- Rendered mode: a second `Renderer` on a `LayerSurface`; built and wired, not run in a window. It remakes its scene
  on every change (a moment after it); a refit path for sculpt strokes would be faster on big meshes.
- Dynamic topology rebuilds the sculpt tree once per mouse event: fine to a few hundred thousand triangles, slow past
  that (it says so). Per-leaf slack would make it local.
- Mirror's clipping and bisect, bevel's patches with segments > 1 at corners (an n-gon, not a grid), edge slide (GG),
  bridge loops, spin, F3 search, the knife's cuts ending inside a face — not there.
- Builder-made objects: saving places the model where they stand, but the builder's original stays.
- `SceneKind.modelingStage` is a scene of its own; the settings panel may list it.
- M4 Max: time the same perf test; Metal 4 untested.
