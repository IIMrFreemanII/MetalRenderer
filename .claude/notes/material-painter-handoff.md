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
- **Unwrap density:** charts are packed as rectangles.
  - Coverage: character ~0.3, demon ~0.34, box ~0.66.
  - Next step: shape-aware (raster) packing.
  - Also tune the cone (66°), the crease (50°) and the merge.
- **Generators** are calibrated by eye on five objects. Dust and leaks are faint on smooth shapes.
- **Cost** (`PAINTER_PERF=1 PainterTests`, M1 Max):
  - a 2K full composite of five layers: 7.9 ms (on a layer edit);
  - a frame of ten dabs: 1.95 ms (the six full mip chains are likely most of it).
  - The texture set's mips could be made for the touched tiles only.
- **Bakes run on the render thread**, synchronously, when a document first has a generator (0.3–1 s at 2K on the M1 Max). They should move to the background.
- **Deforming objects:**
  - Paint is in the bind pose; it follows the skinning.
  - Paint mode measures a posed object's tiles as it stands, but the crowd keeps moving while painting. It should freeze.
- **Not built:**
  - painted objects aren't displaced;
  - Lumen sees their original material;
  - VSM shadows of painted cut-outs are traced (as procedural cut-outs).
- **Metal 4 paths untried:**
  - the composite runs through `FrameEncoder`;
  - the texel map and bakes run on the Metal 3 queue.
