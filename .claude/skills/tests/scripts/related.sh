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
      Tests/MetalRendererTests/*Tests.swift) add "${name%.swift}" ;;
      Tests/*) add MetalRendererTests ;;                     # a shared helper: every suite uses it
      Sources/MetalRenderer/Shaders/Crowd.metal) add CrowdTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Foliage.metal) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/Intersect.metal) add ShaderSourceTests KernelVariantsTests PlantTracingTests ;;
      Sources/MetalRenderer/Shaders/SDF.metal) add SDFTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/RasterClusters.metal|Sources/MetalRenderer/Shaders/Raster.metal|Sources/MetalRenderer/Shaders/VirtualGeometry.metal) add VGCutTests ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/Shaders/*.metal|Sources/MetalRenderer/Shaders.metal) add ShaderSourceTests KernelVariantsTests ;;
      Sources/MetalRenderer/*.swift)
        case $name in
          Settings*.swift) add SettingsTableTests BenchmarkModesTests ;;
          Benchmark*.swift) add BenchmarkModesTests CapabilitiesTests ;;
          Capabilities.swift|Upscaler.swift|Metal4Backend.swift) add CapabilitiesTests ;;
          ShaderSource.swift|Pipelines.swift|GPUTypes.swift) add ShaderSourceTests KernelVariantsTests ;;
          BVH.swift) add BVHTests CacheTests ;;
          CacheFile.swift|SectionFile.swift|BlueNoise.swift) add CacheTests ;;
          Building*.swift|MeshBuilder.swift) add BuildingTests CityTests ;;
          CityPlan.swift|Scene+City.swift) add CityTests BuildingTests ;;
          Scene+Stress.swift) add StressSceneTests ;;
          Crowd*.swift|SkinnedCharacter.swift|Scene+Crowd.swift) add CrowdTests FBXTests ;;
          FBXReader.swift) add FBXTests ;;
          Foliage*.swift|Scene+Forest.swift) add FoliageTests ForestTests FoliageRuntimeTests ;;
          PlantTracing.swift) add PlantTracingTests FoliageTests ForestTests FoliageRuntimeTests ;;
          Voxel*.swift) add FoliageRuntimeTests SceneBuffersTests ;;
          SDF*.swift|Scene+Shapes.swift) add SDFTests SceneBuffersTests ;;
          GLTFLoader.swift) add GLTFLoaderTests ;;
          ProceduralTextures.swift|MaterialTextures.swift) add ProceduralTextureTests ;;
          Scene.swift|SceneBuffers.swift) add SceneBuffersTests ;;
          LightTree.swift) add LightTreeTests ;;
          RasterScene.swift) add RasterSceneTests ;;
          VSM.swift) add VSMTests ;;
          MeshSDFBuilder.swift|LumenScene.swift) add MeshSDFBuilderTests ;;
          LumenGlobalSDF.swift) add GlobalSDFTests ;;
          TextureStreamer.swift) add TextureStreamerTests ;;
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
