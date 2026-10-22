import Buildings
import EngineCore
import Foundation
import Metal
import Physics
import Plants
import simd

/// The FFT ocean's sizes (Shaders/Water.metal's waterSpectrum / waterFFT / waterAssemble kernels): three cascades of
/// 256 x 256 over tiles of these sides, the longest swell to the smallest chop.
package enum WaterWaves {
    package static let size = 256
    package static let cascades = 3
    package static let lengths: [Float] = [233, 41.3, 7.9]
}
