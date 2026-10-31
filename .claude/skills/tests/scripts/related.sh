#!/usr/bin/env bash
# Runs the test suites that cover what changed, never the whole suite.
#
#   related.sh                    suites for the changes against HEAD (uncommitted and untracked files)
#   related.sh --base <rev>       suites for the changes since <rev> (e.g. main, HEAD~1)
#   related.sh --dry-run          print the suites and the files no suite covers; run nothing
#   related.sh <Suite>...         run these suites (e.g. CityTests BuildingTests), skip the map
#
# Maps each changed file to its suites with the table below (the same as the tests skill's SKILL.md) and runs
# swift test --filter on them, in the dev build (Tools/build.sh test: optimised, incremental). Files no suite covers are listed: prove those with images (the offscreen skill).
# A new source or test file goes into the table here and in SKILL.md.
set -euo pipefail

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
base=HEAD
dry=0
suites=" "
add() { local s; for s in "$@"; do [[ $suites == *" $s "* ]] || suites+="$s "; done; }

while (($#)); do
  case $1 in
    -h|--help) usage 0 ;;
    --base) base=${2:?--base needs a revision}; shift ;;
    --dry-run|-n) dry=1 ;;
    -*) echo "related.sh: unknown option $1" >&2; usage 1 ;;
    *) add "$1" ;;
  esac
  shift
done

# Suites for a Swift source, by its file name. Fails when the name isn't in the table.
by_name() {
  case $1 in
    SceneNavigation.swift|SceneGizmo.swift) add SceneNavigationTests ;;   # the gizmo's pictures: SCENE_GIZMO_PNG=<folder>
    DayClock.swift|DayBar.swift) add DayClockTests ;;   # the bar's pictures: DAY_BAR_PNG=<folder>
    Scene+Paint*.swift|Renderer+Painter.swift) add PainterTests ;;
    Scene+Procedural.swift|Scene+Materials.swift|Scene+Displacement.swift)
      add MaterialEditorTests MaterialDisplacementTests SceneBuffersTests MirelandTests ;;
    Scene+Mireland.swift) add MirelandTests MaterialEngineTests ;;
    GraphCanvas.swift) add VFXEditorTests MaterialEditorTests ProjectGraphTests ;;   # the graph editors' shared canvas
    SourceTree.swift) add ShaderSourceTests EXRImageTests MaterialGraphTests ;;   # where the shaders and fixtures are found
    Settings*.swift|SceneSettings.swift) add SettingsTableTests BenchmarkModesTests ;;
    SceneDefinition.swift|GameScenes*.swift|Scene+Kit.swift) add SceneRegistryTests SettingsTableTests BenchmarkModesTests ;;
    SceneChange.swift|SceneLoadQueue.swift|SceneSession.swift) add SceneSwitchTests ;;
    Benchmark*.swift) add BenchmarkModesTests CapabilitiesTests ;;
    Script*.swift|SceneCommand.swift|Renderer+Scripting.swift|Scene+Stage.swift) add ScriptingTests ;;
    SceneFile.swift|Scene+SceneFile.swift|Renderer+Placement.swift) add SceneFileTests ScriptingTests ;;
    Capabilities.swift|Upscaler.swift|Metal4Backend.swift) add CapabilitiesTests ;;
    ShaderSource.swift|GPUTypes.swift) add ShaderSourceTests KernelVariantsTests ;;
    Pipelines.swift) add ShaderSourceTests KernelVariantsTests PipelineCacheTests ;;
    BVH.swift) add BVHTests CacheTests ;;
    CacheFile.swift|SectionFile.swift|BlueNoise.swift) add CacheTests ;;
    Building*.swift|MeshBuilder.swift|BuiltInBuildings.swift) add BuildingTests CityTests BuildingPlanTests BuildingEditorTests BuildingWorkshopTests WalkerTests ;;
    PlanEdits.swift|FloorPlanView.swift|PropLibrary.swift) add BuildingEditorTests BuildingPlanTests ;;
    FurnitureKit.swift) add BuildingPlanTests BuildingWorkshopTests ;;
    Walker.swift|InteriorControls.swift|InteriorLifts.swift) add WalkerTests BuildingWorkshopTests ;;
    Scene+Buildings.swift|Scene+Interiors.swift) add BuildingWorkshopTests CityTests WorldTests WalkerTests ;;
    CatalogRegistry.swift) add PlantCatalogTests PlantEditorTests BuildingEditorTests ;;
    CityPlan.swift|Scene+City.swift) add CityTests BuildingTests ProjectGraphTests ;;
    Scene+Stress.swift) add StressSceneTests ;;
    SkinnedCharacter.swift) add CrowdTests FBXTests MuscleTests CharacterBaseTests CharacterFaceTests ;;   # (the muscles' rig poses its bones by it)
    Crowd*.swift|Scene+Crowd.swift) add CrowdTests FBXTests CharacterBaseTests CharacterFaceTests CharacterHairTests ;;
    CharacterSkin.swift) add CharacterSkinTests CharacterBaseTests ;;
    CharacterHair*.swift) add CharacterHairTests ;;
    Character*.swift) add CharacterDNATests CharacterBaseTests CharacterFaceTests CharacterSkinTests CharacterHairTests CharacterEditorTests ;;   # (and Characters/Editor/*: its model)
    Face*.swift) add CharacterBaseTests CharacterFaceTests CharacterSkinTests CharacterHairTests ;;
    Scene+Characters.swift) add CharacterBaseTests CharacterHairTests ;;
    FBXReader.swift) add FBXTests ;;
    Foliage*.swift|Scene+Forest.swift) add FoliageTests ForestTests FoliageRuntimeTests PlantGoldenTests PlantCatalogTests ProjectGraphTests ;;
    PlantTracing.swift) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ;;
    Plant*.swift) add PlantGoldenTests PlantCatalogTests PlantWorkshopTests PlantEditorTests PlantProgramTests PlantStageTests PlantCompilerTests PlantSwiftTests FoliageTests ForestTests ;;
    Scene+Plants.swift) add PlantWorkshopTests PlantGoldenTests ;;
    Voxel*.swift) add FoliageRuntimeTests SceneBuffersTests ;;
    SDF*.swift|Scene+Shapes.swift) add SDFTests SceneBuffersTests PhysicsTests CharacterBaseTests ;;
    Physics*.swift|Scene+Physics.swift|Scene+Ragdolls.swift|Scene+Hair.swift|Scene+Soft.swift|Scene+Muscles.swift) add PhysicsTests RagdollTests HairTests SoftBodyTests MuscleTests FluidTests ProjectGraphTests ;;
    FluidSurface.swift|Scene+Fluids.swift) add FluidTests ;;
    Particle*.swift|Scene+Particles.swift|Scene+Effects.swift) add ParticleTests VFXTests ;;
    MuscleAtlas.swift|SkeletonAtlas.swift) add MuscleTests CharacterBaseTests ;;
    HairBSDF.swift) add HairTests ;;
    GLTFLoader.swift) add GLTFLoaderTests ;;
    ProceduralTextures.swift|MaterialTextures.swift) add ProceduralTextureTests ;;
    Scene.swift|Scene+Animation.swift|Scene+GPUData.swift|Scene+Construction.swift|Scene+EmissiveLights.swift|Scene+Models.swift|Scene+MeshGenerators.swift|Scene+CrowdParts.swift|Scene+PhysicsWorld.swift|SplitMix64.swift)
      add SceneBuffersTests ProjectGraphTests ;;   # (its outline's tags, the overrides' way in)
    SceneBuffers.swift) add SceneBuffersTests SDFTests ;;   # (the SDF boxes' descriptors, Metal 4's too)
    LightTree.swift) add LightTreeTests ;;
    TextureStreamer.swift) add TextureStreamerTests ;;
    LoadActivity.swift) add LoadActivityTests ;;
    World+Water.swift) add WorldTests WaterTests ;;
    World*.swift|Scene+World.swift|Terrain.swift) add WorldTests SceneBuffersTests ;;
    Scene+Water.swift|Renderer+Water.swift) add WaterTests ;;   # and images (the offscreen skill: METALRENDERER_BENCH=water)
    Scene+Terrain*.swift|Renderer+Terrain.swift) add TerrainDocumentTests TerrainEditorTests ;;
    Showcase.swift|Scene+Showcase.swift) add ShowcaseTests ;;
    VirtualGeometryBuilder.swift) add CacheTests VGStreamerTests ;;
    MeshSimplifier.swift|MeshClusterizer.swift) add CacheTests VGStreamerTests CharacterBaseTests ;;   # and the builder's output (images)
    VirtualBLAS.swift) add VGCutTests ;;
    VirtualTracing.swift) add VGCutTests VGStreamerTests ;;   # and images: no suite traces it
    TraceScene.swift|RenderTargets.swift|Renderer.swift|Renderer+*.swift) return 1 ;;   # the folder's, or images (the offscreen skill)
    *) return 1 ;;
  esac
}

# Suites for a Swift source, by its feature folder. Fails when the folder has none.
by_folder() {
  case $1 in
    # The editors (Sources/Editors, a module of its own: the editors' UI on the engine's models)
    Sources/Editors/Modeling/*.swift) add ModelingEditorTests ModelingViewportTests ;;
    Sources/Modeling/Sculpt/*.swift) add ModelingSculptTests ModelingDynTopoTests ModelingEditorTests ;;
    Sources/Modeling/Modifiers/*.swift) add ModelingModifierTests ModelingSculptTests ;;
    Sources/Modeling/Viewport/*.swift) add ModelingViewportTests ModelingEditorTests ;;
    Sources/Modeling/IO/*.swift|Sources/Modeling/UV/*.swift) add ModelingIOTests ModelingOpsTests ;;
    Sources/Modeling/*.swift) add ModelingMeshTests ModelingOpsTests ModelingTransformTests ModelingModifierTests ModelingIOTests ;;
    Sources/MetalRenderer/Modeling/*.swift) add SceneFileTests ModelingIOTests ;;
    Sources/Editors/VFX/*.swift) add VFXEditorTests ;;
    Sources/Editors/Terrain/*.swift) add TerrainEditorTests ;;
    Sources/Editors/MaterialGraph/*.swift) add MaterialEditorTests ;;
    Sources/Editors/Painter/*.swift) add PainterTests ;;
    Sources/Editors/Plants/*.swift) add PlantEditorTests ;;
    Sources/Editors/Buildings/*.swift) add BuildingEditorTests ;;
    Sources/Editors/Characters/*.swift) add CharacterEditorTests ;;
    Sources/Editors/ProjectGraph/*.swift) add ProjectGraphTests ;;
    # The systems' modules and the engine's side of each (Sources/<Module>/<Feature>, Sources/MetalRenderer/<Feature>)
    Sources/MetalRenderer/VFX/VFXLive.swift) add VFXTests ParticleTests VFXEditorTests ;;
    Sources/Effects/*.swift|Sources/MetalRenderer/VFX/*.swift) add VFXTests ParticleTests ;;
    Sources/Landscape/Water/*.swift|Sources/MetalRenderer/Water/*.swift) add WaterTests ;;
    Sources/Landscape/Terrain/TerrainWater.swift) add WaterTests TerrainDocumentTests ;;
    Sources/Landscape/Terrain/*.swift|Sources/MetalRenderer/Terrain/*.swift) add TerrainDocumentTests TerrainEditorTests ;;
    Sources/Landscape/World/*.swift) add WorldTests SceneBuffersTests ;;
    Sources/MetalRenderer/ProjectGraph/*.swift) add ProjectGraphTests ;;
    Sources/Materials/Painter/UV*.swift|Sources/Materials/Painter/PaintMesh.swift) add PainterUnwrapTests PainterTests ;;
    Sources/Materials/Painter/*.swift|Sources/MetalRenderer/Painter/*.swift) add PainterTests ;;
    Sources/Materials/MaterialGraph/*.swift|Sources/MetalRenderer/MaterialGraph/*.swift) add MaterialGraphTests MaterialEngineTests MaterialEditorTests MaterialDisplacementTests ;;
    Sources/Physics/Cars/*.swift|Sources/MetalRenderer/Cars/*.swift|Sources/Game/Cars/*.swift) add CarTests CarDamageTests CarContactTests PhysicsThreadsTests ;;
    Sources/Physics/*.swift) add PhysicsTests PhysicsThreadsTests RagdollTests HairTests SoftBodyTests MuscleTests FluidTests DestructionTests ;;
    Sources/Characters/*.swift) add CharacterBaseTests CrowdTests CharacterEditorTests ;;
    Sources/Buildings/*.swift) add BuildingTests CityTests BuildingPlanTests BuildingEditorTests WalkerTests ;;
    Sources/Plants/*.swift) add FoliageTests PlantCatalogTests PlantEditorTests ;;
    Sources/EngineCore/*.swift) add ShaderSourceTests CacheTests SceneBuffersTests ;;
    *) return 1 ;;
  esac
}

uncovered=()
if [[ $suites == " " ]]; then
  files=$( { git -C "$repo" diff --name-only "$base" --; git -C "$repo" ls-files --others --exclude-standard; } | sort -u)
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    name=${f##*/}
    case $f in
      Tests/MetalRendererTests/Plants/FoliageTests.swift) add FoliageTests ForestTests FoliageRuntimeTests ;;   # three suites in one file
      Tests/MetalRendererTests/VFX/LegacyEffects.swift) add VFXTests ;;   # the golden test's fixture
      Tests/MetalRendererTests/*Tests.swift) add "${name%.swift}" ;;
      Tests/*) add MetalRendererTests ;;                     # a shared helper: every suite uses it
      Sources/MetalRenderer/Shaders/Crowd.metal) add CrowdTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Foliage.metal) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Intersect.metal) add ShaderSourceTests KernelVariantsTests PlantTracingTests ;;
      Sources/MetalRenderer/Shaders/SDF.metal) add SDFTests PhysicsTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Physics.metal) add PhysicsTests RagdollTests HairTests SoftBodyTests MuscleTests FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Fluid.metal|Sources/MetalRenderer/Shaders/FluidSurface.metal) add FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Liquid.metal) add FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/LightTree.metal) add LightTreeTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Water.metal|Sources/MetalRenderer/Shaders/WaterCommon.metal) add WaterTests ShaderSourceTests KernelVariantsTests ;;   # and images (waterKernel: the offscreen skill)
      Sources/MetalRenderer/Shaders/Hair.metal) add HairTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/ParticleSim.metal|Sources/MetalRenderer/Shaders/ParticleLight.metal|Sources/MetalRenderer/Shaders/ParticleTrace.metal) add ParticleTests VFXTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/ShadersVFX.metal) add VFXTests ShaderSourceTests ;;
      Sources/Modeling/Shaders/*.metal) add ModelingViewportTests ModelingEditorTests ;;
      Sources/MetalRenderer/Shaders/Procedural.metal|Sources/MetalRenderer/Shaders/Pick.metal) add ShaderSourceTests KernelVariantsTests MaterialGraphTests ;;
      Sources/MetalRenderer/Shaders/*.metal|Sources/MetalRenderer/Shaders.metal) add ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/MaterialShaders/Paint*.metal) add PainterTests ;;
      Sources/MetalRenderer/MaterialShaders/*.metal|Sources/MetalRenderer/ShadersMaterial*.metal)
        add MaterialGraphTests MaterialEngineTests MaterialEditorTests MaterialDisplacementTests ;;
      Sources/*.swift)   # every module's: EngineCore, MetalRenderer, Editors, Game
        # By the file's name first, then by its folder; in a bash case, * also matches /.
        by_name "$name" || by_folder "$f" || uncovered+=("$f") ;;
      Package.swift) add MetalRendererTests ;;
      *) ;;                                                  # skills, docs, tools, assets: no unit test
    esac
  done <<< "$files"
fi

# A change every suite depends on runs them all, as one filter.
[[ $suites == *" MetalRendererTests "* ]] && suites=" MetalRendererTests "

if ((${#uncovered[@]})); then
  echo "no suite covers (prove with images, the offscreen skill):"
  printf '  %s\n' "${uncovered[@]}"
fi

list=$(echo $suites)
if [[ -z $list ]]; then
  echo "no unit tests cover this change"
  exit 0
fi
filter=${list// /|}
echo "suites: $list"
((dry)) && exit 0
cd "$repo"
exec "$repo/Tools/build.sh" test --filter "$filter"
