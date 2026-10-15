# Character creator: handoff

Branches `claude/procedural-character-creation-cb1a51` (PR 1), `claude/character-face-cb1a51` (PR 2),
`claude/character-skin-hair-cb1a51` (PR 3), each stacked on the one before. Plan: `~/.claude/plans/implement-procedural-character-creation-rustling-teapot.md`
(on the M1 Max). README: "The character editor".

## Decisions (the user's)

- Morph the Mixamo **Y Bot / X Bot** and keep the Mixamo skeleton (every library clip plays). Realistic style: the
  mannequin's skin is rebuilt as one surface and a face is **sculpted procedurally** (no downloads).
- v1 content: body, face **with expressions** (blink, look-at, smile/frown/surprise, visemes), hair (strands up close,
  caps in crowds), skin with subsurface and detail maps, procedural garments **plus cloth-sim** skirts/capes/coats.
- Editor: tabbed SwiftUI panel like the plant editor; workshop with pose switch, face close-up, lineup, compare.
- NPCs: archetypes (mean, spread, correlations), ~32 unique bodies per crowd scene; physics scenes opt in.
- H toggles the panel, menu ⌘Y. **One PR per phase**, each verified offscreen before the next.

## Phases

1. **Body pipeline + workshop + Body editor (this PR).** DNA, store, params, macro rig, base body (lofted trunk, rebuilt
   hands, sparse surface nets, weight transfer), body morphs, builder, kit cache, workshop, editor (Body / Proportions /
   Skin tabs), `crowd,cast=generated`, bench `characters` and `charactercrowd`.
2. **Face + expressions (PR 2).** `FaceSculpt` (the head as a distance field: cranium, face, jaw, neck, brow ridge,
   cheekbones, eye sockets with lid shells and their openings cut, nose and nostrils, lips with the mouth cut into a
   mouth, ears with a stalk into the skull), meshed at 1 mm apart from the body (2.5 mm) and sewn to it at the neck
   (`CharacterBase.stitched`); `FaceParts` (eyeballs with cornea, iris and pupil rings; teeth; tongue; the per-vertex
   materials: lips, brows, mouth); `FaceRig` (expression targets with normal deltas, lid and eye rotation groups) run
   in `crowdSkinKernel` per slot; `FacePlayer` (blinks, expressions, speech, gaze); face sliders and the macros' face
   targets (`CharacterFaceMorphs.swift`); the Face tab (sections with their own dice, the expression preview, eyes on the
   camera) and the eye colour.
3. **Skin + hair (PR 3, branch `claude/character-skin-hair-cb1a51`, stacked on PR 2's).** Skin: `GPUMaterial.params.w
   < 0` (strength, + 2 thin), `skinUnshadowed`/`skinShadowOrigin` in `Shaders/Hair.metal` (wrapped diffuse per channel,
   light through the ears and nostrils' wings from shadow rays started past them), carried through the G-buffer's
   `geoNormal.w` (minus the code) to every lighting path and the path tracer; shader feature bit 17 `SKIN`. UVs
   (`SkinAtlas`: angle round the head's axis folded at the face's middle, by height; body on the plain last row),
   `SkinChart` (each texel's point of the head), `SkinTextures` (colour, roughness, normals from landmarks and DNA).
   Hair: `CharacterHair` (9 styles, 5 beards, brows, lashes; guides + clumped children; roots bound to base
   triangles), `crowdHairKernel` after the skinning (scalp by the head's palette, the rest by their triangle's frame),
   `CharacterHairCap` (strand volume + scalp shell, meshed, per level, cached) for crowds and `hairs=caps`. Skin & Hair
   tab (style and beard pickers with locks, colour and cut sliders, skin marks, hair mode).
4. Clothes: garment shells bound to the body, fabrics, body hiding, `addClothMesh` with kinematic pins.
5. NPC archetypes, 32 baked bodies with clip dedupe, city sidewalk crowd (opt-in), physics `characterBody=generated`.

## Deviations from the plan, and why

- **No GPU morph pass in PR 1.** Remaking the workshop at each edit takes 11 ms for one character on the M1 Max (morph +
  reshape 5 ms on the CPU, buffers and BLAS 6 ms): live enough at 30 edits a second. The GPU morph kernel comes with
  expressions (PR 2), which need per-frame face morphs anyway.
- **The trunk is a loft, not the Y Bot's.** The Y Bot's trunk (24 cm waist, 29 cm deep pelvis, panel edges) can't be
  smoothed into a person; `CharacterBase.TrunkLoft` (stations of anthropometric widths/depths, matched to the Y Bot at its
  ends) is blended in by `trunkness` (up to 80%). The female shape is the female loft (breasts included) less the male
  one, not the X Bot's skin (whose panels made the chest crumple); only the X Bot's skeleton is used.
- No UVs on the base yet (PR 3 needs them for detail maps).
- **PR 2: no eye joints, no jaw joint.** The Mixamo rig has neither, and adding joints would mean widening every clip.
  The eyes and lids turn by rotation groups about the eyes' centres in the skinning kernel (the CPU computes each slot's
  turns: gaze through the head joint's skinning matrix), the jaw opens by a morph (a rotation about the hinge, weighted).
- **PR 2: no symmetry toggle.** Every face slider moves both sides alike; asymmetry can come as its own slider later.
- **PR 2: the brows and lips are materials on the skin's triangles**, edges kept by locking the simplifier there.
  PR 3: brows are strands in the workshop (the material only darkens the skin under them); crowds keep painted brows.
- **PR 3: hair is not simulated.** The plan had a kinematic head body in the physics; strands are carried rigidly by the
  head (scalp) and by their triangles (brows, lashes, beard), which follows every clip and expression and costs no
  physics, but nothing swings. Long hair can go through the shoulders in some poses (it is kept off them only in the T pose).
- **PR 3: one texture layout for the head only** (no body charts): the body's UVs are the textures' plain last row, so
  the body has no pores or marks. The fold makes the textures symmetric (freckles and moles mirror).
- **PR 3: lashes as strands** (not in the plan): roots on the lids' edge vertices, they blink with the lids.

## Traps found

- BodySurface's `distance` is clamped to its band far from the skin: mixing two fields with hard cut planes left flaps
  and rims; a smooth spatial mix (`trunkness`) of the two distances fixed them, with the loft's end stations set to the
  Y Bot's measured sections.
- Sparse surface nets need the active bricks dilated by one, or a quad whose cells straddle an inactive brick is lost
  (a hole on the shin).
- Weight transfer from the Y Bot: its panels each ride one bone, so the transferred weights step at panel seams (the neck
  tore under the uppercut clip): 12 smoothing passes, hands excluded (their weights are analytic).
- The X Bot's skeleton is not shorter than the Y Bot's: sex scales height by 0.93 explicitly.
- Skin stretch over every clip: 99.9% of edges within 3.4x (the Y Bot's rigid panels: 1.3x; a one-piece skin folds at
  the groin and armpits under linear blend skinning).

- The head's simplification flattened thin features (ears to 7% of their vertices): the simplifier now keeps
  vertices where the surface bends sharply (24 degrees between neighbours' normals) and where materials meet.
- An ear stood a millimetre off the head and `largestPart` dropped it: the concha's stalk ties it into the skull.
- The face close-up's camera: `Camera.framing` keeps 20 cm round any box; the face view places its camera itself.
- The kit's cache key doesn't include the build options: after changing the sculpt, delete
  `Assets/.metalrenderer-cache/character-kit-*` (or bump `CharacterKit.version`). Hair caps are cached there too
  (`hair-cap-*`, keyed by style, kit version and base size; bump `CharacterHairCap.version` after changing the cap).
- PR 3: the ear's bowl was carved through its shell, a pit into the head that showed as a bright dot in close-ups
  since PR 2: the bowl now has a floor and a thicker root (the field probe along the ear's axis said solid; a ray cast
  against the mesh found it).
- PR 3: surface nets on a grid field fling vertices where the grid is flat (a cap vertex 90 m away made every ray in
  the crowd 8x slower): the cap's gradient is floored (as MuscleAtlas's), its vertices clamped to its box, and a level
  the simplifier throws a vertex off from is replaced by the level before.
- PR 3: skin code in the lights cost every scene 0.27 ms of the crowd's trace even without skin: behind `SKIN` now.
- PR 3: face close-ups in `-m characters` render at full resolution (1920x1200 native): at 640x400 upscaled, pores and
  wrinkles are a texel or two and vanish.

## Open

- A small flap at a woman's waist side in some dance frames (skinning, not geometry: the T pose is clean).
- Breasts' upper edge creases a little; the trunk still reads a bit tubular for the man. Polish when the face is in.
- Metal 4 and the M4 Max: not run. Run `METALRENDERER_BENCH=characters` and `charactercrowd` under both APIs there
  (hair curves: hardware curves on the M4 Max should make strands much cheaper than the M1 Max's 35 ms remake).
- Hair: strands are a pixel or less wide in close-ups (dotted look with 1 sample a pixel); lashes and brows read best
  with the lash line and the darkened brow skin under them. Long hair hangs in rather regular clumps.
- Caps are plain shells (no strand texture); fine at crowd distance, a helmet close up.
