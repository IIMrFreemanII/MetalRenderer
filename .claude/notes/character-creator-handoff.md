# Character creator: handoff

Branch `claude/procedural-character-creation-cb1a51`. Plan: `~/.claude/plans/implement-procedural-character-creation-rustling-teapot.md`
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
3. Skin + hair: `GPUMaterial.params.w < 0` = skin (wrapped diffuse, red-shifted, thin-part transmission), `SkinTextures`,
   strand hair on a kinematic head + caps for crowds, Skin & Hair tab. Needs UVs on the base (not made yet).
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
  Strand brows and texture-painted lips come with PR 3's UVs and skin textures.

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
  `Assets/.metalrenderer-cache/character-kit-*` (or bump `CharacterKit.version`).

## Open

- A small flap at a woman's waist side in some dance frames (skinning, not geometry: the T pose is clean).
- Breasts' upper edge creases a little; the trunk still reads a bit tubular for the man. Polish when the face is in.
- Metal 4 and the M4 Max: not run. Run `METALRENDERER_BENCH=characters` and `charactercrowd` under both APIs there.
