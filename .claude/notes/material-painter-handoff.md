# Material Painter: handoff

Branch `claude/graphify-update-746c89` (PR #60, with the Material Designer and Mireland). Built on the M1 Max,
2026-10-10. The README's "The Material Painter" says what it is; this note says where things are and what is left.

## Where things are
- `Painter/`: the engine.
  - `PaintMesh` (a mesh out of the scene, bind pose)
  - `UVCheck` / `UVUnwrap` / `UVPack` (the layout)
  - `PaintDocument` (layers, masks, generators; `PaintDocuments` registry, thread-safe)
  - `PaintAssignments` (per scene)
  - `PainterSession` (GPU texture set, strokes, undo)
  - `PaintBrush` (dabs, stamps)
  - `PaintBake` (mesh maps, generators)
  - `PaintMeshMaps` (the Mesh Map node's pictures)
  - `SmartMaterial`
  - `PainterPixels` (save/load/export/pictures)
  - `GLBWriter`
- `Scene+Painted.swift`: painted materials, corner UVs, the atlas cache (`GeneratedCache`, key `painter atlas v<UVUnwrap.version>`).
- `Scene+Painter.swift`: the workshop.
- `Renderer+Painter.swift`: sessions, install, paint mode, fills, ring, status.
  - Hooks in `Renderer.swift`: `encodePainting` after `encodeDisplacement`, mouse routing, `encodeGizmos` (ring), `benchmarkActs` (`PainterStep` scripts).
- `MaterialShaders/Paint.metal`: texel map, dilate, tiles, dabs, apply, composite, normal, copies, readback, thumbnails.
- `MaterialShaders/PaintBake.metal`: AO/thickness (RT), curvature, generators, position/normal maps.
- Shading: `Surface.metal` reads painted corners when the extras' `textures.z` has its top bit set (offset to the GPU UV buffer).
- `Intersect.metal` `rtOpacity`: the mesh index's top bit means the same.
- `PainterEditor/`: window (`PainterPanel`, `PainterModel`, `PainterView`). V opens, Shift-V walks.

## Verified (offscreen, tests)
- `-m painter`: bricks laid by UV on sphere, cube, cylinder, plane, character, demon.
- `-m painterstrokes`, sphere and demon. All of these show:
  - the stroke, with occlusion;
  - the eraser;
  - leaf stamps;
  - symmetry;
  - a mask stroke revealing gold;
  - an island fill;
  - the height in the normal;
  - the ring.
- `-m paintersmart`: the five smart materials. Edge wear on the cube, rust on the demon, wood plus dirt on the character.
- Tests: `PainterUnwrapTests`, `PainterTests` (GPU composite + stroke + undo/redo).

## Not verified / next
- **The window and paint mode by hand** (never opened): picking, Tab, right-drag orbit, pen pressure, thumbnails, the 2D view, Save/Export dialogs.
- **Unwrap density:** charts are packed by their outlines (`UVPack`: a horizon per half-gutter column, four quarter turns, score = top + 4 x the room left under it per column; a scale search from below).
  - Coverage at 2K: character 0.445 (was 0.30), demon 0.39 (0.34), sphere 0.68 (0.65), cylinder 0.81, box 0.65.
  - The character's largest chart (16k triangles) is long; cutting long charts would raise it further.
  - Also tune the cone (66°), the crease (50°) and the merge (the demon unwraps to 1,499 charts, median 2 triangles).
- **Generators** are calibrated by eye on five objects. Dust and leaks are faint on smooth shapes.
- **Cost** (`PAINTER_PERF=1 PainterTests`, M1 Max):
  - a 2K full composite of five layers: 5.2 ms (on a layer edit);
  - a frame of ten dabs: 1.42 ms (was 1.95: the levels are now made for the touched tiles only, `paintDownsample`, instead of six full mip chains by blit; this also keeps Metal 4 off its Metal 3 interlude for mips).
- **Bakes** run off the render thread (`PaintBakeJob`, a queue of its own, occlusion and curvature in bands of 128K texels so the frames get the GPU between them); benchmarks still bake at once. Generated masks themselves (`PaintBake.generate`) still wait on the render thread (one dispatch, a few ms).
- **Deforming objects:**
  - Paint is in the bind pose; it follows the skinning.
  - Paint mode holds the scene's animation time (`Renderer` frame update), so a posed object stays where its tiles were measured.
- **Own UVs** now have their texels per metre (their UV area over the surface's): UV-projected fills and the height's normal are to scale on imported models (they tiled ~millions of times before: the demon showed only mortar).
- **Not built:**
  - painted objects aren't displaced;
  - Lumen sees their original material;
  - VSM shadows of painted cut-outs are traced (as procedural cut-outs).
- **Metal 4 paths untried:**
  - the composite runs through `FrameEncoder`;
  - the texel map and bakes run on the Metal 3 queue.
