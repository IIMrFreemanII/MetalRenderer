import Buildings
import Metal
import Physics
import Plants
import simd

// The water's look shared with the shaders (Shaders/Water*.metal). Its memory layout MUST match the MSL struct of the
// same name exactly (validateGPULayouts, in the engine, checks it).

/// Catches accidental layout drift between Swift and MSL at startup.
/// One body of water's look (MSL WaterLook, WaterLook.gpu): a table of them, which the water map and the water's
/// surfaces' triangles name.
package struct GPUWaterLook {
    package var absorption: SIMD4<Float>   // rgb = per metre, w = index of refraction
    package var scattering: SIMD4<Float>   // rgb = per metre, w = phase g
    package var waves: SIMD4<Float>        // x = share of the wind's sea, y = chop, z = ripples, w = roughness
    package var foam: SIMD4<Float>         // x = crest foam, y = shore foam width (m), z = white water, w = flow speed (m/s)
}
