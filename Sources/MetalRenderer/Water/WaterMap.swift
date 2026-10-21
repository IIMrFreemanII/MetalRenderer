import Characters
import Effects
import EngineCore
import Foundation
import Physics
import Plants
import simd

/// The water map around the camera (Shaders/WaterCommon.metal waterAt): two squares of texels, a near one of a metre
/// and a far one of eight, each 1024 a side, holding per texel the water's surface (or none), the ground under it, its
/// flow, its look and how white it runs. The shading reads it for the shore (how deep the water is), the rivers' flow,
/// the light under the water and whether the camera is in it. Drawn on the CPU from the scene's WaterField, a level
/// at a time in the background whenever the camera has gone a quarter of the way to its edge.
enum WaterMap {
    static let size = 1024
    static let cells: [Double] = [1, 8]
    static let dry: Float = -1e9

    /// One level drawn: the world's x, z of texel (0, 0)'s corner, its metres a texel, and its texels.
    struct Level {
        package var origin: SIMD2<Double>
        package var cell: Double
        package var surface: [SIMD2<Float>]   // (level or `dry`, ground)
        package var info: [UInt32]            // RGBA8: flow x, flow z (v / 8 + 0.5), look / 255, turbulence
    }

    /// Where level `k`'s square goes for a camera at `at` (the world's x, z): centred on it, snapped to 64 texels.
    static func origin(level k: Int, at: SIMD2<Double>) -> SIMD2<Double> {
        let cell = cells[k], snap = cell * 64, half = cell * Double(size) / 2
        return SIMD2((at.x / snap).rounded() * snap - half, (at.y / snap).rounded() * snap - half)
    }

    /// Whether level `k` drawn at `origin` should be drawn again for a camera at `at`.
    static func stale(level k: Int, origin: SIMD2<Double>, at: SIMD2<Double>) -> Bool {
        let half = cells[k] * Double(size) / 2, centre = origin + half
        return simd_reduce_max(simd_abs(at - centre)) > half / 4
    }

    static func draw(_ field: WaterField, level k: Int, origin: SIMD2<Double>) -> Level {
        let n = size, cell = cells[k]
        var surface = [SIMD2<Float>](repeating: SIMD2(dry, 0), count: n * n)
        var info = [UInt32](repeating: 0x0000_8080, count: n * n)
        surface.withUnsafeMutableBufferPointer { s in
            info.withUnsafeMutableBufferPointer { inf in
                let sp = s.baseAddress!, ip = inf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: n / 16) { band in
                    field.draw(rows: band * 16..<(band + 1) * 16, origin: origin, cell: cell, size: n, surface: sp, info: ip)
                }
            }
        }
        return Level(origin: origin, cell: cell, surface: surface, info: info)
    }

    static func pack(_ w: WaterSample) -> UInt32 {
        func byte(_ v: Float) -> UInt32 { UInt32(min(max(v, 0), 1) * 255 + 0.5) }
        return byte(w.flow.x / 8 + 0.5) | byte(w.flow.y / 8 + 0.5) << 8 | UInt32(min(max(w.look, 0), 254)) << 16 | byte(w.turbulence) << 24
    }
}
