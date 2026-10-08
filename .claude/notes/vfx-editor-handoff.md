# VFX editor: handoff (branch claude/init-branch-94ae07, PR #54)

The particle effects as node graphs, and an editor for them (README "VFX graphs"). The plan, with the user's choices:
~/.claude/plans/implement-modern-particle-system-typed-origami.md. Three phases, a check-in after each.

## The user's choices

- Everything is a graph (a full dataflow graph: contexts of blocks, operator nodes wired into their pins).
- A separate SwiftUI window, dark, typed pins, curved wires, a minimap.
- Preview on a VFX stage and in the loaded scene.
- Edits live, rebuilding only when needed; real curves and gradients.
- JSON files plus Copy as Swift; one graph is one effect, placed in scenes.
- The built-in effects bit-identical; the CPU copy an interpreter of the graph.
- The window may be opened at check-ins to click through.

## Phase 1 (graph model, code generator, compile, interpreter, ports): done, at check-in 1

- `Sources/MetalRenderer/VFX/`:
  - `VFXGraph` (the model, Codable);
  - `VFXNodes` (the catalogue);
  - `VFXLowering` (graph → ParticleEmitter: Tier A);
  - `VFXProgram` + `VFXCodegen` (Tier B: Metal and the CPU's closures from one walk);
  - `VFXCompiler` (the VFX library: `ShadersVFX.metal`, async, LRU of 6);
  - `VFXInterpreter` (was ParticlesCPU; ParticleMath keeps the maths);
  - `VFXBuilder` (Swift builders, `swiftSource`);
  - `VFXStore` + `VFXCatalog` (Assets/Effects, the editor's registry, `SceneSettings.effects`);
  - `VFXLibrary` (the built-in effects, `fireworks`, `named`).
- `Scene+Effects.swift` (addEffect, addParticleCollider, addEffects); `Scene+Stage.swift` (the VFX stage, minimal: a dark studio,
  `SceneSettings.stage.effects`).
- `Shaders/Particles.metal` split into `ParticleSim.metal` (+ `#ifdef VFX_PROGRAMS` prelude and hooks) and `ParticleLight.metal`.
- Benchmarks: `vfx` (the stage's stills and timing), `vfxdemo` (16 s video).
- Tests: `VFXTests` (8).

## Phase 2 (the editor window): done, at check-in 2

- `Sources/MetalRenderer/VFXEditor/`:
  - `VFXEditorModel` (behind `VFXEditorHost`, testable without a window): the catalog as edited and as saved, undo by snapshots
    (a drag is one step), the draft, Save, Revert, Copy as Swift, the graph's edits, copy and paste of nodes;
  - `VFXLayout` (the canvas's geometry; arranges effects never laid out);
  - `VFXCanvasView`, `VFXInspector` (with curve and gradient editors), `VFXEditorView`, `VFXEditorPanel` (an NSWindow; its
    `VFXHostingView` takes the scroll, pinch and keys);
  - `VFXEditorScript` (`METALRENDERER_VFX_SCRIPT`: the editor driven in the app, printing the renderer's report).
- `VFX/VFXLive.swift` + `Renderer.editEffects`: an edit changes only `SceneSettings.effects`.
  - Values: `ParticlesGPU.adopt` writes them into new buffers, so the frames in flight keep the old ones.
  - New code: it compiles while the old code runs (`pendingEffects`), then is swapped in and replayed.
  - Otherwise the scene is made again.
  - Benchmarks take the same path (`applyBenchmarkConfig`; mode `vfxedit`).
- `Scene.addEffect(builtIn:)`: a catalog's copy of a built-in effect is moved from its origin to the scene's place.
- V / ⇧⌘E opens it (`RendererController.onToggleVFX`, main.swift).
- Not clicked through by hand: no tool here sends clicks to a native window. The scripted session and the offscreen pictures
  stand in for it.

## Phase 3 (preview tools, backdrops, gizmos): done, at check-in 3

- The preview bar (`VFXEditorView.swift`): Stage / In Scene, the backdrop, transport (play, restart, step, speed), the
  timeline (`Renderer.setTime`: back replays), gizmos, stats.
- Backdrops (`VFXBackdrop`, `Scene+Stage.swift`): dark (the phase 1 room), grey cyclorama, black, outdoor, night.
  The stage orbits (`SceneKind.orbits`); `focus` from `Scene.previewBounds` (the interpreter, 4 s).
- Gizmos: `VFX/VFXGizmos.swift` (segments, picking, the drag's maths), `Shaders/Gizmo.metal` (`gizmoLinesKernel`, a thread
  a point along a segment, over the drawable after post), `Renderer.encodeGizmos` / `mouseDown`. A drag goes to the
  main thread (`onGizmoMoved`) and moves the emitter's Spawn Shape position (adds one if it has none).
- Stats: `ParticlesGPU.aliveCounts` (capacity less the dead list), `VFXStatus.passMs` (the particle passes while the
  stats show: `profilePasses`, which the Debug window also sets).
- Not done: a per-emitter GPU time (the plan's "Profile" dispatching emitters one at a time); gizmos for fields' and
  colliders' handles (they are drawn, not draggable); the gizmos aren't depth tested.

## Next

M4 Max checks (Metal 4 path of the VFX library and the gizmo pass), then the PR's description.

## Traps found

- The renderer isn't deterministic run to run in the particles scene: the GPU's atomics hand out pool slots in their own
  order, and each slot's light is averaged over frames. Two runs of one binary differ by up to 80 levels (rms ~0.2-0.27),
  so "bit-identical" was checked as: the descriptors, the pool, colliders and fields byte for byte (`VFXTests`), and the
  frames within that noise against a baseline build.
- Field order matters to the frames (not to the particles): with the fields listed the other way round, a 2 s → 5 s jump
  rendered the smoke a little differently (rms 0.93 against 0.27), every time. The particles stepped the same (a GPU
  experiment: all but one dust particle, which is the events' own order). Most likely the buffer layout sways the
  atomics' order and so each slot's light history. The particles scene places the rubble first to keep the old order.
- Fast math: the same statements compile differently in another library. Fixed emitters in a system with programs (the
  VFX library) differ from the main library's by an ulp (the newborn's `life = a + (b - a) * u`); keeping the dispatchers
  out of line made it worse (positions too). A scene without programs runs the main library: unchanged.
- A Trigger's condition holds for many steps: its children's seeds come from their parent's, so each step's eight went the
  same eight ways (dotted lines). The simulate kernel (VFX library) and the interpreter mix the step into a program's
  events' seed.
- An `init` parameter label in Swift (`init: VFXInitPlan`) reads as the initializer inside the function.
- `related.sh` maps `Package.swift` to the whole suite: name the suites instead.
