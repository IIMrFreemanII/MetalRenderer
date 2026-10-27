# Procedural modelling: handoff

Branch `claude/procedural-modelling-tools-94e880`. Built 2026-10-27 (the M1 Max's worktree). README "Procedural
modelling" says what it is; this note says where things are, what was checked and what is left.

## Where things are
- `Sources/Procedural` (module, on EngineCore, Physics, Modeling):
  - `Geo/`: `ProcGeo` (points / vertices / primitives / detail), `AttributeTable` + `AttributeValues` (typed columns,
    gather / blend / append), `GroupPattern` + `PointGrid`, `GeoBuilder` (topology from source rows: attributes ride
    along), `EditMeshBridge` (to and from `EditMesh`, attribute transfer after the modeller's ops).
  - `Graph/`: `ProcGraph` (nodes, links, interface), `ProcParam`.
  - `Nodes/`: `ProcNodeKind` (+ spec table), `ProcNodeKind+Cook` (dispatch), one file per family.
  - `Cook/ProcCooker`: keys by hash, LRU cache, For-Each passes (`forEach`).
  - `Wrangle/`: `WrangleSource` (rewrites `@` bindings), `WrangleContext` (columns, edits), `WrangleCompiler`
    (swiftc -O + dynamic lookup, bundle cache), `WrangleFunctions`.
  - `Asset/ProcAsset`: `ProcAsset`, `ProcAssetReference` (`proc:slug?k=v`), `ProcStore`, the cooked-mesh cache.
- `Sources/Editors/Modeling/Procedural`: `ProceduralSession` (the network on the active object, cooks, undo, flags,
  assets), `ProcNetworkView` (GraphCanvas, nodes, Tab menu, info, host), `ProcParameterPane`, `ProcInspect`
  (handles, normals, Cd colours, numbers, spreadsheet), `ProcTheme`, `ProceduralScripting` (scripted steps).
- `ModelObject.network` (JSON) in `Sources/Modeling`, saved in `.mrmesh`; the viewport's `template` draws.
- `Sources/Editors/Placement`: the main window's Object inspector (a placed `proc:` copy's values, written through
  `Renderer.setPlacedAsset` / `editPlaced`; `RendererStatus.placed`; `placedReselect` keeps the copy selected).
- `Sources/MetalRenderer/Procedural/Scene+ProcAsset.swift` (`proc:` in `Scene.place`), hot reload of
  `Assets/Procedural` (DevReload). Demo: `Assets/Procedural/*.proc.json`, `Assets/Scenes/procedural.scene`, the
  `procedural` scene kind in `GameScenes` (the stage's builder). `ProceduralDemo` in `ProceduralAssetTests` makes them.

## Verified
- All eight Procedural suites green in the dev build, with ModelingEditorTests, ModelingScriptTests,
  ModelingIOTests, ModelingViewportTests, SceneRegistryTests, SettingsTableTests, SceneFileTests, BenchmarkModesTests.
- The fence posts' shaded sides were black with radiance cascades (no probe on a 1-2 px face): fixed in
  RadianceCascades.metal (cascade 0 traces the bins below a probe's surface; the resolve falls back to the distance
  weights where no probe matches). `-m procedural` renders the scene with cascades, path traced and the GI views.
- Window pictures (MODELING_PNG): the tab with a network, the spreadsheet. Offscreen render of the Procedural scene
  (default look and path traced): every asset cooks at load and places.
- Main merged 2026-10-27; `switches.py` and `switches.py --saved` pass with the procedural scene in the tour (loads in
  ~440 ms) and in `remake` (Scripts/scene-switches.swift: its assets cooked again, as a hot reload or the inspector's
  edit). The scene is the stage's builder plus placed objects (no systems of its own).
- Wrangles compile and run in the test process; the first compile ~8 s (module cache), later ones under a second.

## Not done / next
- Never shown in the window by hand (no window unasked): the network's scroll / pinch / keys inside the Modeller's
  window, the handle drags with a real mouse, the code editor's focus are checked through the model only;
  so is the Object inspector panel (its model by tests, its edits in a headless app, its look in offscreen pictures).
- `.claude/skills/tests/scripts/related.sh` has no rows for `Sources/Procedural`, `Editors/Modeling/Procedural`
  (the skills folder is write-protected here): add `Sources/Procedural/*` → the nine Procedural suites, and
  `Sources/Editors/Placement/*` → ObjectInspectorTests.
- Performance: cooks are off the frame. `ProceduralPerfTests` (PROC_PERF=1, release) times a 1M scatter (and relaxed),
  10k copies, a 1M wrangle, a 100k-point sweep; README has the M4 Max numbers. `testAttributeWrites` times the row-by-row
  attribute nodes, conversions and merge loops (`PROC_PERF_SIDE=100` for an unoptimised build, where they were
  quadratic: fixed). `testRay` and `testVoronoi`: Ray through a triangle tree (17–47× faster), Voronoi's cells on every
  core with the input's BSP tree built once (35–49×), same fingerprints. What Voronoi has left is spread out: the cells'
  clipping (`ConvexCell.size` per cut), the booleans' own clipping, the neighbours' sort.
- Expressions in parameters (`Sources/Procedural/Expr`: parser, a compiler that folds what doesn't vary, a stack VM
  per element): `ProceduralExpressionTests`, the editor's in `ProceduralEditorTests.testExpressionsAndTheFrame`. Not
  there yet: expressions on menus and toggles typed in (a toggle shows a field once it has one), Python expressions,
  `chramp`, `$HIP`-style paths, absolute node paths, a channel's keyframes; a placed asset doesn't animate (its
  `frame=` is fixed).
- Not there: packed primitives in the viewport, VDB / volumes,
  curve drawing in the viewport, edge groups, a ramp editor beyond the key list, network boxes / sticky notes,
  subnetworks.
