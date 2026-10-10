// The material graph library's entry (MatCompiler): the kernels that bake a graph's nodes (MatEngine) and the
// renderer's textures from its outputs. Its own library, compiled once in the background when a graph is first baked.

#include <metal_stdlib>
using namespace metal;

#include "MaterialShaders/MatCommon.metal"
#include "MaterialShaders/MatNoise.metal"
#include "MaterialShaders/MatPatterns.metal"
#include "MaterialShaders/MatAdjust.metal"
#include "MaterialShaders/MatFilters.metal"
#include "MaterialShaders/MatHeight.metal"
#include "MaterialShaders/MatAdvanced.metal"
#include "MaterialShaders/MatDisplace.metal"
