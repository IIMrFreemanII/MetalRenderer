// The entry of a pixel processor's or a Code node's library (MatCompiler): what their generated kernels call, and
// the generated code spliced in after it. Small, so an edit of the code compiles in a moment.

#include <metal_stdlib>
using namespace metal;

#include "MaterialShaders/MatCommon.metal"
