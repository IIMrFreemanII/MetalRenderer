import Metal
import MetalFX

/// What the running GPU and system can do, asked once at launch (`main.swift`). The settings panel disables the
/// options that need something missing, `RenderSettings.clamped(to:)` swaps them for ones that work, and the
/// benchmark skips the settings that need them.
struct Capabilities: Equatable {
    var metalRayTracing = true      // Metal's acceleration structures and intersector
    var hardwareRayTracing = true   // ... traversed by ray-tracing hardware (Apple9: M3, A17 Pro and later), not in software
    var metalFXUpscaling = true     // MetalFX temporal and spatial scalers
    var metalFXDenoiser = true      // MetalFX denoising scaler (macOS 26)
    var metal4 = true               // Metal 4's command queue, argument tables and compiler (macOS 26)

    /// The running device's. Everything until `main` sets it: tests have no device.
    static var current = Capabilities()

    init() {}

    /// `METALRENDERER_CAPS="rt,metalfx"` keeps only the capabilities it names (rt, hwrt, metalfx, denoiser, metal4;
    /// `none` keeps nothing), to try the fallbacks on a GPU that has them all.
    init(device: MTLDevice, env: [String: String] = ProcessInfo.processInfo.environment) {
        metalRayTracing = device.supportsRaytracing
        hardwareRayTracing = metalRayTracing && device.supportsFamily(.apple9)
        metalFXUpscaling = MTLFXTemporalScalerDescriptor.supportsDevice(device)
        if #available(macOS 26.0, *) {
            metalFXDenoiser = MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device)
            metal4 = device.supportsFamily(.metal4)
        } else {
            metalFXDenoiser = false
            metal4 = false
        }
        if let keep = env["METALRENDERER_CAPS"]?.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            metalRayTracing = metalRayTracing && keep.contains("rt")
            hardwareRayTracing = hardwareRayTracing && metalRayTracing && keep.contains("hwrt")
            metalFXUpscaling = metalFXUpscaling && keep.contains("metalfx")
            metalFXDenoiser = metalFXDenoiser && keep.contains("denoiser")
            metal4 = metal4 && keep.contains("metal4")
        }
    }

    /// One line for the launch log.
    var summary: String {
        func mark(_ on: Bool) -> String { on ? "yes" : "no" }
        let rt = !metalRayTracing ? "no" : hardwareRayTracing ? "hardware" : "software"
        return "Metal ray tracing: \(rt), MetalFX upscaling: \(mark(metalFXUpscaling)), MetalFX denoiser: \(mark(metalFXDenoiser)), Metal 4: \(mark(metal4))"
    }
}

extension RenderSettings {
    /// What these settings need that `caps` lacks, as text ("MetalFX denoiser"); nil when they can run as they are.
    func missing(in caps: Capabilities) -> String? {
        var needs: [String] = []
        if rayTracer == .metal && !caps.metalRayTracing { needs.append("Metal ray tracing") }
        if upscaleFactor > 1 && upscaler == .metalFXDenoised && !caps.metalFXDenoiser { needs.append("the MetalFX denoiser") }
        if api == .metal4 && !caps.metal4 { needs.append("Metal 4") }
        return needs.isEmpty ? nil : needs.joined(separator: " and ")
    }

    /// The settings with every option that `caps` lacks swapped for the default one, and what was swapped.
    func clamped(to caps: Capabilities) -> (settings: RenderSettings, notes: [String]) {
        var s = self, notes: [String] = []
        if s.rayTracer == .metal && !caps.metalRayTracing {
            s.rayTracer = .custom
            notes.append("Metal ray tracing is not supported on this GPU: using the custom BVH")
        }
        if s.upscaler == .metalFXDenoised && !caps.metalFXDenoiser {
            s.upscaler = .custom
            notes.append("The MetalFX denoiser is not supported on this GPU or system: using the custom upscaler and SVGF")
        }
        if s.api == .metal4 && !caps.metal4 {
            s.api = .metal3
            notes.append("Metal 4 is not supported on this GPU or system: using Metal 3")
        }
        return (s, notes)
    }
}
