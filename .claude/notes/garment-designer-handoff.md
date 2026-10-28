# Garment designer: handoff

Branch `claude/garment-designer-tool-9d4863`. Plan: `~/.claude/plans/implement-garment-designer-like-joyful-bunny.md`.
README: "The garment designer".

## Decisions (the user's)

- Like Marvelous Designer: 2D pattern | 3D avatar | inspector, its own window with a second engine renderer, dark theme.
- Dresses both: the designer's avatars (the **Y Bot and X Bot** by default, any saved character) and characters in
  scenes and crowds (skinned bakes; live sim opt-in).
- Authoring: hand-drawn panels, parametric templates, grading to body measurements, Procedural graph nodes.
- Features: sewing (1:1, N:1), arrangement, GPU drape, drag, freeze, fabric presets + sheen, darts, folds, elastics,
  buttons, layering, topstitch, clips, point-cache bakes, OBJ/GLB/DXF exports. Space toggles the sim.
- One big branch, milestones checked offscreen.
- Shortcut: Option-Cmd-G (Shift-Cmd-G was taken by the Project Graph).

## State

Done: every milestone of the plan (M0–M11) in a first version, checked with `-m garments`, `-m garmentdrape`,
`-m garmentwalk`, `-m garmentcrowd` and the scripted designer (`garments` socket request, window captures).

## Deviations and why

- **Seams pair by arc length on both sides** (a point to a point or to a segment), not merged vertices: panels keep
  their own UVs, N:1 seams need no matching counts.
- **Bending is dihedral everywhere** (Bridson's gradients, checked numerically), not Bergou's isometric model: one
  formula for flat cloth, folds and seams. Bending across a seam is off while it closes (it held panels apart).
- **Compliances**: the particles weigh ~0.1 g, so bending's softest is 3000 (Fabric.bendSoftest); with 2 the cloth was
  cardboard.
- **Arrangement**: limbs wrap each row of a panel all the way round at its own radius (a sleeve's seam closed through
  the arm otherwise); the trunk's front and back lean in over the shoulders (their seams met through the body).
- **Moving avatars collide with the rig's capsules**, posed from the crowd's palette each frame, not with the skinned
  triangles (the plan's): simpler, and the trunk's capsules are thick enough; the static avatar uses BodySurface.
- **Sheen** is folded into the hit's albedo from the view (every lighting path reads the albedo), packed in the
  metallic lane (≤ -1), feature bit 9 — not a separate BRDF lobe in each path.
- **Crowds** drape on the CPU (GarmentSim) once per outfit and body (cached in ~/Library/Caches/MetalRenderer) and
  bind there; every generated body of the same mesh wears it. Skin weights: the bound triangle's heaviest corner's.
- The tests skill's map has no Garments row: `.claude/skills` is write-protected here (needs the user's OK).

## Next

- Self-collision is vertex–vertex only (no edge–edge, no CCD); fast motions can tunnel a thin layer.
- Skirts and coats in skinned crowds stretch between the legs (no pelvis blending of weights yet).
- The 3D view has no seam/pin overlay lines yet (gizmoLines); picking is by nearest particle to the ray.
- Hero live sim in game scenes (`addLiveGarment`) isn't there: the workshop's stage is the only live cloth.
- Release-build timings and `hotcalls.py` for the CPU drape loop; `switches.py` with the garment workshop in the tour.
