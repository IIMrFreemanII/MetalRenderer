// MetalRenderer shaders: ray traced direct light + path traced global illumination + SVGF-style denoiser.
// Compiled at runtime (Pipelines.compile) — press R in the app to hot-reload after editing. This file is the entry:
// the code lives in Shaders/, spliced in below by ShaderSource.swift (the runtime compiler has no include path).

#include <metal_stdlib>
using namespace metal;

// CUSTOM_RT (set by Pipelines.compile): 1 = this file's own BVH traversal (Shaders/Intersect.metal),
// 0 = Metal's acceleration structures and intersector.
#ifndef CUSTOM_RT
#define CUSTOM_RT 1
#endif
#if !CUSTOM_RT
#include <metal_raytracing>
using namespace metal::raytracing;
#endif

// In this order: a piece may use what the pieces above it declare.
#include "Shaders/Types.metal"             // structs shared with GPUTypes.swift, flags, flagOn / passOn
#include "Shaders/Sampling.metal"          // hashes, Rng, Sampler (blue noise), hemisphere sampling
#include "Shaders/Foliage.metal"           // generated plants: the wind that turns their parts
#include "Shaders/SDF.metal"               // SDF shapes: their distance fields and the march through them
#include "Shaders/Intersect.metal"         // Ray, Hit and the ray queries: Metal's intersector or the custom BVH traversal
#include "Shaders/Surface.metal"           // SceneData, sky lookups, the specular BRDF, materials, traceSurface
#include "Shaders/Raster.metal"            // the raster visibility buffer: culling, the pyramid, the draw, visibilityHit
#include "Shaders/Lights.metal"            // every light type's evaluation, shadow targets, picks, the light table
#include "Shaders/Regir.metal"             // the light grid (ReGIR) and regirBuildKernel
#include "Shaders/LightSampling.metal"     // light samples and RIS, octahedral mapping, light-visibility maps, view directions
#include "Shaders/Fog.metal"               // volumetric fog: fogInject / fogIntegrate / fogReference
#include "Shaders/Sky.metal"               // atmosphere, clouds, the sky map and its noise
#include "Shaders/Trace.metal"             // traceKernel, many lights, their reuse, mesh lights
#include "Shaders/Glass.metal"             // glassKernel: window panes over the traced G-buffer
#include "Shaders/RestirDI.metal"          // ReSTIR direct light: temporal and spatial reuse
#include "Shaders/MegaLights.metal"        // MegaLights-style direct light: tile light lists, MIS-combined samples
#include "Shaders/RestirGI.metal"          // ReSTIR GI: initial paths, temporal and spatial reuse
#include "Shaders/Reflections.metal"       // reflectionKernel (specular materials)
#include "Shaders/Denoise.metal"           // SVGF temporal, a-trous, the shadow denoiser
#include "Shaders/Output.metal"            // geometry debug views, composite, tone map, accumulate
#include "Shaders/Post.metal"              // the lens and the finish: depth of field, bloom, vignette, grain
#include "Shaders/RadianceCascades.metal"  // the radiance cascades GI mode
#include "Shaders/BVHBuild.metal"          // custom ray tracer: the per-frame top-level tree (rt* kernels)
#include "Shaders/VirtualGeometry.metal"   // virtual geometry: the frame's cut and its tree (vg* kernels)
#include "Shaders/Crowd.metal"             // skinned characters: pose slots' matrices, vertices and trees (crowd* kernels)
