import Characters
import Effects
import EngineCore
import Metal
import MetalFX
import Physics
import Plants

/// What the running GPU and system can do, asked once at launch (`App.swift`). The settings panel disables the
/// options that need something missing, `RenderSettings.clamped(to:)` swaps them for ones that work, and the
/// benchmark skips the settings that need them.
package struct Capabilities: Equatable {
    package var metalRayTracing = true      // Metal's acceleration structures and intersector: the renderer needs them
    package var hardwareRayTracing = true   // ... traversed by ray-tracing hardware (Apple9: M3, A17 Pro and later), not in software
    package var metalFXDenoiser = true      // MetalFX denoising scaler (macOS 26): the upscaler
    package var frameInterpolator = true    // MetalFX frame interpolator (macOS 26): an in-between picture each frame
    package var metal4 = true               // Metal 4's command queue, argument tables and compiler (macOS 26)
    /// Metal 4's acceleration structures, for Metal ray tracing on Metal 4. Metal has no query for it, only a validation
    /// error ("this device does not support Metal 4 ray tracing", M1 Max); the M4 Max, with ray-tracing hardware, has it.
    package var metal4RayTracing = true

    /// The running device's. Everything until `main` sets it: tests have no device.
    package static var current = Capabilities()

    package init() {}

    /// `METALRENDERER_CAPS="rt,denoiser"` keeps only the capabilities it names (rt, hwrt, denoiser, interpolator, metal4;
    /// `none` keeps nothing), to try the fallbacks on a GPU that has them all.
    package init(device: MTLDevice, env: [String: String] = ProcessInfo.processInfo.environment) {
        metalRayTracing = device.supportsRaytracing
        hardwareRayTracing = metalRayTracing && device.supportsFamily(.apple9)
        if #available(macOS 26.0, *) {
            metalFXDenoiser = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
            frameInterpolator = MTLFXFrameInterpolatorDescriptor.supportsDevice(device)
            metal4 = device.supportsFamily(.metal4)
            metal4RayTracing = metal4 && hardwareRayTracing
        } else {
            metalFXDenoiser = false
            frameInterpolator = false
            metal4 = false
            metal4RayTracing = false
        }
        if let keep = env["METALRENDERER_CAPS"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            metalRayTracing = metalRayTracing && keep.contains("rt")
            hardwareRayTracing = hardwareRayTracing && metalRayTracing && keep.contains("hwrt")
            metalFXDenoiser = metalFXDenoiser && keep.contains("denoiser")
            frameInterpolator = frameInterpolator && keep.contains("interpolator")
            metal4 = metal4 && keep.contains("metal4")
            metal4RayTracing = metal4RayTracing && metal4 && hardwareRayTracing
        }
    }

    /// One line for the launch log.
    package var summary: String {
        func mark(_ on: Bool) -> String { on ? "yes" : "no" }
        let rt = !metalRayTracing ? "no" : hardwareRayTracing ? "hardware" : "software"
        return "Metal ray tracing: \(rt), MetalFX denoiser: \(mark(metalFXDenoiser)), frame interpolator: \(mark(frameInterpolator)), "
            + "Metal 4: \(mark(metal4)) (ray tracing: \(mark(metal4RayTracing)))"
    }
}

extension RenderSettings {
    /// What these settings need that `caps` lacks, as text ("MetalFX denoiser"); nil when they can run as they are.
    package func missing(in caps: Capabilities) -> String? {
        var needs: [String] = []
        if !caps.metalRayTracing { needs.append("Metal ray tracing") }
        if upscaleFactor > 1 && !caps.metalFXDenoiser { needs.append("the MetalFX denoiser") }
        if upscaleFactor > 1 && frameInterpolation == .on && !caps.frameInterpolator { needs.append("the MetalFX frame interpolator") }
        if api == .metal4 && !caps.metal4 { needs.append("Metal 4") }
        if api == .metal4 && caps.metalRayTracing && caps.metal4 && !caps.metal4RayTracing {
            needs.append("Metal 4 ray tracing")
        }
        return needs.isEmpty ? nil : needs.joined(separator: " and ")
    }

    /// The settings with every option that `caps` lacks swapped for the default one, and what was swapped. (Metal ray
    /// tracing has no stand-in: the renderer refuses a GPU without it.)
    package func clamped(to caps: Capabilities) -> (settings: RenderSettings, notes: [String]) {
        var s = self, notes: [String] = []
        if s.upscaleFactor > 1 && !caps.metalFXDenoiser {
            s.upscaleFactor = 0
            notes.append("The MetalFX denoiser is not supported on this GPU or system: upscaling is off, SVGF denoises")
        }
        if s.frameInterpolation != .off && !caps.frameInterpolator {
            if s.frameInterpolation == .on { notes.append("The MetalFX frame interpolator is not supported on this GPU or system: it is off") }
            s.frameInterpolation = .off
        }
        if s.api == .metal4 && !caps.metal4 {
            s.api = .metal3
            notes.append("Metal 4 is not supported on this GPU or system: using Metal 3")
        }
        if s.api == .metal4 && !caps.metal4RayTracing {
            s.api = .metal3
            notes.append("Metal 4 ray tracing is not supported on this GPU: using Metal 3 with Metal ray tracing")
        }
        return (s, notes)
    }
}
