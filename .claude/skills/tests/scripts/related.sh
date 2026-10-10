#!/usr/bin/env bash
# Runs the test suites that cover what changed, never the whole suite.
#
#   related.sh                    suites for the changes against HEAD (uncommitted and untracked files)
#   related.sh --base <rev>       suites for the changes since <rev> (e.g. main, HEAD~1)
#   related.sh --dry-run          print the suites and the files no suite covers; run nothing
#   related.sh <Suite>...         run these suites (e.g. CityTests BuildingTests), skip the map
#
# Maps each changed file to its suites with the table below (the same as the tests skill's SKILL.md) and runs
# swift test --filter on them. Files no suite covers are listed: prove those with images (the offscreen skill).
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

uncovered=()
if [[ $suites == " " ]]; then
  files=$( { git -C "$repo" diff --name-only "$base" --; git -C "$repo" ls-files --others --exclude-standard; } | sort -u)
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    name=${f##*/}
    case $f in
      Tests/MetalRendererTests/FoliageTests.swift) add FoliageTests ForestTests FoliageRuntimeTests ;;   # three suites in one file
      Tests/MetalRendererTests/LegacyEffects.swift) add VFXTests ;;   # the golden test's fixture
      Tests/MetalRendererTests/*Tests.swift) add "${name%.swift}" ;;
      Tests/*) add MetalRendererTests ;;                     # a shared helper: every suite uses it
      Sources/MetalRenderer/Shaders/Crowd.metal) add CrowdTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Foliage.metal) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Intersect.metal) add ShaderSourceTests KernelVariantsTests PlantTracingTests ;;
      Sources/MetalRenderer/Shaders/SDF.metal) add SDFTests PhysicsTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Physics.metal) add PhysicsTests RagdollTests HairTests SoftBodyTests MuscleTests FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Fluid.metal|Sources/MetalRenderer/Shaders/FluidSurface.metal) add FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Liquid.metal) add FluidTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Hair.metal) add HairTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/ParticleSim.metal|Sources/MetalRenderer/Shaders/ParticleLight.metal|Sources/MetalRenderer/Shaders/ParticleTrace.metal) add ParticleTests VFXTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/RasterClusters.metal|Sources/MetalRenderer/Shaders/Raster.metal|Sources/MetalRenderer/Shaders/VirtualGeometry.metal) add VGCutTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/ShadersVFX.metal) add VFXTests ShaderSourceTests ;;
      Sources/MetalRenderer/Shaders/Procedural.metal|Sources/MetalRenderer/Shaders/Pick.metal) add ShaderSourceTests KernelVariantsTests MaterialGraphTests ;;
      Sources/MetalRenderer/Shaders/*.metal|Sources/MetalRenderer/Shaders.metal) add ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/VFX/VFXLive.swift) add VFXTests ParticleTests VFXEditorTests ;;
      Sources/MetalRenderer/VFX/*.swift) add VFXTests ParticleTests ;;
      Sources/MetalRenderer/VFXEditor/*.swift) add VFXEditorTests ;;
      Sources/MetalRenderer/GraphEditor/*.swift) add VFXEditorTests MaterialEditorTests ;;
      Sources/MetalRenderer/MaterialGraph/*.swift|Sources/MetalRenderer/MaterialShaders/*.metal|Sources/MetalRenderer/ShadersMaterial*.metal)
        add MaterialGraphTests MaterialEngineTests MaterialEditorTests MaterialDisplacementTests ;;
      Sources/MetalRenderer/MaterialEditor/*.swift) add MaterialEditorTests ;;
      Sources/MetalRenderer/Scene+Procedural.swift|Sources/MetalRenderer/Scene+Materials.swift|Sources/MetalRenderer/Scene+Displacement.swift)
        add MaterialEditorTests MaterialDisplacementTests SceneBuffersTests RasterSceneTests ;;
      Sources/MetalRenderer/*.swift)
        case $name in
          Settings*.swift) add SettingsTableTests BenchmarkModesTests ;;
          Benchmark*.swift) add BenchmarkModesTests CapabilitiesTests ;;
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
          CityPlan.swift|Scene+City.swift) add CityTests BuildingTests ;;
          Scene+Stress.swift) add StressSceneTests ;;
          SkinnedCharacter.swift) add CrowdTests FBXTests MuscleTests CharacterBaseTests CharacterFaceTests ;;   # (the muscles' rig poses its bones by it)
          Crowd*.swift|Scene+Crowd.swift) add CrowdTests FBXTests CharacterBaseTests CharacterFaceTests CharacterHairTests ;;
          CharacterSkin.swift) add CharacterSkinTests CharacterBaseTests ;;
          CharacterHair*.swift) add CharacterHairTests ;;
          Character*.swift) add CharacterDNATests CharacterBaseTests CharacterFaceTests CharacterSkinTests CharacterHairTests CharacterEditorTests ;;   # (and CharacterEditor/*: its model)
          Face*.swift) add CharacterBaseTests CharacterFaceTests CharacterSkinTests CharacterHairTests ;;
          Scene+Characters.swift) add CharacterBaseTests CharacterHairTests ;;
          FBXReader.swift) add FBXTests ;;
          Foliage*.swift|Scene+Forest.swift) add FoliageTests ForestTests FoliageRuntimeTests PlantGoldenTests PlantCatalogTests ;;
          PlantTracing.swift) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ;;
          Plant*.swift|BuiltInPlants.swift) add PlantGoldenTests PlantCatalogTests PlantWorkshopTests PlantEditorTests FoliageTests ForestTests ;;
          Scene+Plants.swift) add PlantWorkshopTests PlantGoldenTests ;;
          Voxel*.swift) add FoliageRuntimeTests SceneBuffersTests ;;
          SDF*.swift|Scene+Shapes.swift) add SDFTests SceneBuffersTests PhysicsTests CharacterBaseTests ;;
          Physics*.swift|Scene+Physics.swift|Scene+Ragdolls.swift|Scene+Hair.swift|Scene+Soft.swift|Scene+Muscles.swift) add PhysicsTests RagdollTests HairTests SoftBodyTests MuscleTests FluidTests ;;
          FluidSurface.swift|Scene+Fluids.swift) add FluidTests ;;
          Particle*.swift|Scene+Particles.swift|Scene+Effects.swift) add ParticleTests VFXTests ;;
          MuscleAtlas.swift|SkeletonAtlas.swift) add MuscleTests CharacterBaseTests ;;
          HairBSDF.swift) add HairTests ;;
          GLTFLoader.swift) add GLTFLoaderTests ;;
          ProceduralTextures.swift|MaterialTextures.swift) add ProceduralTextureTests ;;
          Scene.swift|SceneBuffers.swift) add SceneBuffersTests ;;
          LightTree.swift) add LightTreeTests ;;
          RasterScene.swift) add RasterSceneTests ;;
          VSM.swift) add VSMTests ;;
          MeshSDFBuilder.swift|LumenScene.swift) add MeshSDFBuilderTests ;;
          LumenGlobalSDF.swift) add GlobalSDFTests ;;
          TextureStreamer.swift) add TextureStreamerTests ;;
          LoadActivity.swift) add LoadActivityTests ;;
          World*.swift|Scene+World.swift|Terrain.swift) add WorldTests SceneBuffersTests ;;
          Showcase.swift|Scene+Showcase.swift) add ShowcaseTests ;;
          VirtualGeometryBuilder.swift) add CacheTests VGStreamerTests ;;
          VGStreamer.swift|VirtualGeometry.swift|RasterClusters.swift) add VGStreamerTests VGCutTests ;;
          VirtualBLAS.swift) add VGCutTests ;;
          VirtualTracing.swift) add VGCutTests VGStreamerTests ;;   # and images: no suite traces it
          TraceScene.swift|Renderer.swift) uncovered+=("$f") ;;    # images (the offscreen skill)
          *) uncovered+=("$f") ;;
        esac ;;
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
exec swift test --filter "$filter"
