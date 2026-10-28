import Foundation
import simd

/// What a panel is cut from: how the cloth stretches, shears and bends (stiffnesses 0...100, a slider's scale, as
/// Marvelous Designer gives them), how heavy and thick it is, how it slides on the body, and how it looks.
/// `GarmentBuild` turns the stiffnesses into the solver's compliances (`compliance`).
package struct Fabric: Codable, Equatable {
    package enum Preset: String, Codable, CaseIterable {
        case cotton, denim, silk, leather, knit, wool
    }
    package var name: String
    /// Against stretching along the warp (the grain line) and the weft (across it), and against shearing.
    package var warp: Float
    package var weft: Float
    package var shear: Float
    package var bending: Float
    /// Weight per area (g/m²).
    package var density: Float
    package var friction: Float
    /// Its thickness (metres): how far apart its layers and the body stay.
    package var thickness: Float
    /// How it moves: 0 (it keeps moving) to 1 (it settles at once).
    package var damping: Float = 0.2
    package var color: SIMD3<Float>
    package var roughness: Float
    /// The sheen of its fibres (0...1) and how spread that sheen is (0...1): velvet and knits glow at grazing angles.
    package var sheen: Float
    package var sheenRoughness: Float
    /// Light through it (0...1): silk and thin knits.
    package var translucency: Float = 0

    package static func preset(_ p: Preset) -> Fabric {
        switch p {
        case .cotton:
            return Fabric(name: "Cotton", warp: 60, weft: 55, shear: 40, bending: 25, density: 150, friction: 0.6, thickness: 0.0015,
                          color: [0.78, 0.76, 0.72], roughness: 0.85, sheen: 0.3, sheenRoughness: 0.6)
        case .denim:
            return Fabric(name: "Denim", warp: 85, weft: 80, shear: 70, bending: 55, density: 380, friction: 0.7, thickness: 0.0025,
                          color: [0.13, 0.2, 0.36], roughness: 0.9, sheen: 0.2, sheenRoughness: 0.7)
        case .silk:
            return Fabric(name: "Silk", warp: 50, weft: 45, shear: 20, bending: 5, density: 80, friction: 0.3, thickness: 0.0008,
                          damping: 0.1, color: [0.62, 0.12, 0.18], roughness: 0.35, sheen: 0.8, sheenRoughness: 0.25, translucency: 0.25)
        case .leather:
            return Fabric(name: "Leather", warp: 95, weft: 95, shear: 85, bending: 75, density: 900, friction: 0.8, thickness: 0.0035,
                          damping: 0.35, color: [0.24, 0.13, 0.07], roughness: 0.55, sheen: 0, sheenRoughness: 0.5)
        case .knit:
            return Fabric(name: "Knit", warp: 25, weft: 15, shear: 15, bending: 15, density: 200, friction: 0.65, thickness: 0.002,
                          color: [0.55, 0.57, 0.6], roughness: 0.95, sheen: 0.6, sheenRoughness: 0.8, translucency: 0.1)
        case .wool:
            return Fabric(name: "Wool", warp: 70, weft: 65, shear: 55, bending: 45, density: 320, friction: 0.75, thickness: 0.003,
                          damping: 0.3, color: [0.3, 0.28, 0.27], roughness: 0.95, sheen: 0.5, sheenRoughness: 0.9)
        }
    }

    /// A stiffness's XPBD compliance (per unit of the constraint's measure): 0 → about 1e-3 (it gives freely), 100 → about
    /// 1e-8 (it barely moves).
    package static func compliance(_ stiffness: Float, softest: Float = 1e-3) -> Float {
        softest * pow(10, -max(0, min(100, stiffness)) / 20)
    }
    /// The compliances at stiffness 0, per constraint kind. A particle of cloth weighs about a tenth of a gram at 2 cm
    /// apart, so its constraints' compliances over a substep's dt² meet inverse masses near 10⁴: stretch stays near
    /// rigid but for a knit, shear gives a little, bending gives (silk folds at a touch, leather barely).
    package static let stretchSoftest: Float = 1e-2, shearSoftest: Float = 1, bendSoftest: Float = 3000
    /// Its mass per square metre (kg).
    package var areaMass: Float { density / 1000 }
}
