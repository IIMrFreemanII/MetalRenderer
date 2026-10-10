// The VFX library's entry (VFXCompiler): the particle kernels with the effects' generated code (VFXCodegen), which
// VFXCompiler splices in after the last piece. Only the pieces they need, so a graph's change compiles in a fraction of
// the whole: Shaders.metal lists the same pieces in the same order.

#include <metal_stdlib>
using namespace metal;

#include <metal_raytracing>
using namespace metal::raytracing;

#define VFX_PROGRAMS 1

#include "Shaders/Types.metal"
#include "Shaders/Sampling.metal"
#include "Shaders/Foliage.metal"
#include "Shaders/SDF.metal"
#include "Shaders/Intersect.metal"
#include "Shaders/ParticleTrace.metal"
#include "Shaders/Surface.metal"
#include "Shaders/ParticleSim.metal"
