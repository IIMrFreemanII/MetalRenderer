import Foundation
import simd

/// How a body of water looks (Shaders/Water.metal): what it absorbs and scatters per metre (Beer-Lambert: clear sea
/// water lets blue through and takes red; a swamp's tannins take blue), its index of refraction and roughness, how
/// much of the wind's sea it has (the FFT ocean's waves, 1 = all of it), its ripples, foam and flow.
package struct WaterLook: Codable, Equatable {
    package enum Preset: String, Codable, CaseIterable, Identifiable {
        case ocean, lake, river, swamp, pool
        package var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    }
    /// Per metre, red green blue.
    package var absorption: SIMD3<Float>
    var scattering: SIMD3<Float>
    var ior: Float = 1.333
    var roughness: Float = 0.02
    /// The share of the wind's sea it has (0: still, a mirror but for its ripples), the waves' sideways push (choppy
    /// crests), the small ripples' strength.
    package var waves: Float
    var chop: Float
    var ripples: Float
    /// Foam where the waves break (0...1), the foam line along the shore (as deep as the water it lies on, m), white water where a river
    /// runs fast (0...1), how fast a river runs in its middle (m/s).
    var foam: Float
    var shoreFoam: Float
    var whiteWater: Float
    var flowSpeed: Float
    /// How forward the light it scatters goes (Henyey-Greenstein g).
    var phase: Float = 0.7

    package static func preset(_ p: Preset) -> WaterLook {
        switch p {
        case .ocean:
            return WaterLook(absorption: [0.5, 0.09, 0.06], scattering: [0.05, 0.07, 0.09], roughness: 0.02, waves: 1, chop: 0.9, ripples: 1,
                             foam: 0.6, shoreFoam: 0.6, whiteWater: 0, flowSpeed: 0)
        case .lake:
            return WaterLook(absorption: [0.55, 0.12, 0.16], scattering: [0.05, 0.07, 0.05], roughness: 0.03, waves: 0.18, chop: 0.5, ripples: 0.8,
                             foam: 0.15, shoreFoam: 0.25, whiteWater: 0, flowSpeed: 0)
        case .river:
            return WaterLook(absorption: [0.7, 0.22, 0.3], scattering: [0.12, 0.13, 0.1], roughness: 0.04, waves: 0.04, chop: 0.3, ripples: 1,
                             foam: 0.1, shoreFoam: 0.2, whiteWater: 0.7, flowSpeed: 1.4)
        case .swamp:
            return WaterLook(absorption: [1.1, 1.6, 2.6], scattering: [0.05, 0.04, 0.02], roughness: 0.05, waves: 0.01, chop: 0.1, ripples: 0.15,
                             foam: 0, shoreFoam: 0, whiteWater: 0, flowSpeed: 0, phase: 0.5)
        case .pool:
            return WaterLook(absorption: [0.35, 0.05, 0.02], scattering: [0.008, 0.01, 0.012], roughness: 0.01, waves: 0.02, chop: 0.2, ripples: 0.3,
                             foam: 0, shoreFoam: 0, whiteWater: 0, flowSpeed: 0)
        }
    }

    /// What a body of its kind looks like unless it says otherwise.
    static func standard(_ kind: WaterBody.Kind) -> WaterLook {
        switch kind {
        case .sea: return .preset(.ocean)
        case .lake: return .preset(.lake)
        case .river: return .preset(.river)
        }
    }

    /// The colour deep water of this look shows (its single-scattering albedo): what GI rays that meet it see, and the
    /// map's swatch.
    var deepColor: SIMD3<Float> {
        let t = absorption + scattering
        return scattering / simd_max(t, SIMD3(repeating: 1e-4)) * 0.35
    }

    var gpu: GPUWaterLook {
        GPUWaterLook(absorption: SIMD4(simd_max(absorption, .zero), max(ior, 1.0001)), scattering: SIMD4(simd_max(scattering, .zero), min(max(phase, -0.95), 0.95)),
                     waves: SIMD4(max(waves, 0), max(chop, 0), max(ripples, 0), min(max(roughness, 0.002), 0.5)),
                     foam: SIMD4(max(foam, 0), max(shoreFoam, 0), max(whiteWater, 0), max(flowSpeed, 0)))
    }
}

extension WaterBody {
    /// Its look: its own, or its kind's.
    var appearance: WaterLook { look ?? WaterLook.standard(kind) }
}
