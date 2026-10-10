# Material Designer: handoff (branch claude/graphify-update-746c89)

A Substance-Designer-like procedural material editor (README "The Material Designer"). Plan, with the user's choices:
~/.claude/plans/implement-procedural-material-designer-curious-rose.md. One branch, a commit per phase, one PR.

## The user's choices

- Results live in the renderer, saved as graph files, exported as PNG/EXR, assignable to any scene's objects.
- Evaluation both ways: baked on the GPU (default) and as shader code for point-wise graphs.
- Every node family (noises, patterns, adjustments, blending, filters, height/normal, advanced incl. flood fill,
  distance, pixel processor as math graph and as Metal code, subgraphs).
- Substance-style window: canvas with thumbnails, 2D view, embedded 3D preview, inspector, library.
- Channels: ORM (AO in R), height with parallax, opacity cutting holes in RT; per-node 8/16/32-bit, grey or colour.
- 3D preview both embedded and as a path-traced material workshop scene. Click-to-pick assignment.
- O / Shift-Cmd-M (M is the GI cycle). Starters: bricks & stone, metals, wood & organic, sci-fi emissive.

## Done (commits on the branch)

- P0 `GraphEditor/GraphCanvas.swift`: the VFX editor's canvas shared (GraphCanvasModel, GraphHostingView...).
- P1 `MaterialGraph/`: MaterialGraph, MatNodes (catalogue), MatFunction, MaterialStore/Catalog, MatPlan, MatLayout.
- P2-P3 MatEngine (+ `ShadersMaterial.metal`, `MaterialShaders/`), MatCompiler, MatExport.
- P4 renderer: GPUMaterialExtra / MaterialExtra (MATERIAL_EXTRAS bit 15), parallax, AO, opacity (OPACITY bit 14:
  TraceScene.opacity, OpacityLevels, non-opaque instances, raster skips them), per-slot texture tables, hot swap
  (Renderer.applyProcedural / updateProcedural / editMaterials), MaterialBake.
- P5 SceneKind.materials (appended last), Scene+Materials, benchmark `materials`.
- P6 `MaterialEditor/` window; P7 Pick (Shaders/Pick.metal, Renderer.encodePick/readPick), MaterialAssignments
  (Assets/Materials/assignments.json, SceneSettings.materialAssignments), planar UVs on UV-less meshes; mode `matedit`.
- P8 MatShaderCode (PROCEDURAL_CODE bit 13, Shaders/Procedural.metal splice marker, SceneShading.procParams; pipeline
  sets know their splice). P9 starters, README, this note.
- P10 displacement (the user asked, after P9: "some materials should look like real bumped mesh shapes, not only flat
  ones"). Choices: workshop + assigned objects; a per-material detail (target edge length, 1M triangles a mesh, 4M a
  scene); displacement + normal map with parallax off on displaced meshes; re-displaced each time a bake lands.
  `MatSurface.displacement/displacementMid/displacementDetail`; `MeshSubdivider` (per-edge midpoint splits: crack-free;
  welds of coincident vertices, angle-weighted group normals); `Scene+Displacement` (a subdivided copy per mesh and
  scale, planar UVs baked for UV-less meshes, bounds grown by `displacementRoom`, shadows traced, scene not still);
  `MaterialShaders/MatDisplace.metal` (in the material library: group-averaged height, mip at the vertex spacing);
  `Renderer.encodeDisplacement` (before the TLAS: kernel, then `DisplacedBuild` rebuilds those BLAS in place, every
  slot's TLAS rebuilt); raster treats them as deforming; `editMaterials` makes the scene again for on/off, another
  detail, or an amount past the room. The embedded preview displaces on the CPU from a <=256 px readback.

## Verified (M1 Max, Metal 3)

- Stock scenes unchanged: A/B of the P4 build against the previous commit: Cornell, sun, plants identical; gallery and
  city differ only by their run-to-run noise (base vs base the same).
- Tests: MaterialGraphTests, MaterialEngineTests, MaterialEditorTests (+ VFXEditorTests, ShaderSourceTests,
  KernelVariantsTests, SceneBuffers/Raster/SettingsTable/BenchmarkModes) all pass.
- Offscreen: `-m materials` (every starter on the line-up), `-m matedit` (an edit in place re-bakes 14 of 17 nodes in
  7 ms; sun courtyard assignments; marble as code matches it baked). The editor window drawn offscreen
  (MATERIAL_EDITOR_PNG); its Metal views (2D, 3D) aren't captured by that.

## Not verified / not done

- The window by hand (no clicks into native windows from here): canvas drags, pickers, pick popover, export panel.
- Metal 4 (argument tables, residency of the procedural textures, OpacityLevels on MTL4): written, untried.
- Opacity on meshes without UVs (the alpha test reads the mesh's UVs), in Lumen and the virtual shadow maps; SDF shapes.
- The open world's tiles can't take assignments. Multi-material meshes: opacity per instance's own material only.
- The tests skill's map (.claude/skills/tests) lacks the new suites: MaterialGraph*/MatEngine/MatShaderCode ->
  MaterialGraphTests MaterialEngineTests; MaterialEditor/* -> MaterialEditorTests; Scene+Procedural, Scene+Materials,
  Shaders/Procedural.metal, Shaders/Pick.metal -> MaterialEditorTests ShaderSourceTests KernelVariantsTests.
  (Protected path: edit it by hand.)

## Traps found

- SwiftUI's Text("\(n)") localizes numbers (1 024): use Text(verbatim:).
- Metal: no derived structs (OpacityLevels copies Levels<false>'s functions through the templates' PLANTS=false).
- SceneShading's extras pointer fitted in the old tail padding (offset 280, size stayed 288); procParams made it 304.
- The renderer's normal maps: green along +V; the graph's Normal node output works as is (no flip) — checked on the
  bricks' bevels under the studio's key light.
- A grey wired into an `any` pin is replicated (R into RGB); a colour into a grey pin is its luminance (matIn).
