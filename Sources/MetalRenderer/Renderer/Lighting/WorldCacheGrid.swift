import simd

/// The world radiance cache's clipmap: pure math, no Metal. Each level is a 32x16x32 window of probe cells that
/// follows the camera; level `l` has cells `base * 3^l` wide. A cell lives at a toroidal slot, so moving the window
/// keeps every cell that stays inside it at the same slot and only the entering cells change.
package struct WorldCacheGrid {
    package static let size = SIMD3<Int32>(32, 16, 32)
    package static let probesPerLevel = 16384
    package static let raysPerProbe = 64

    /// Cell width per level.
    package let spacing: [Float]
    /// Per level, the min-corner cell of the window (zero until `follow`).
    package private(set) var origin: [SIMD3<Int32>]

    package init(levels: Int, spacing base: Float) {
        spacing = (0..<levels).map { base * powf(3, Float($0)) }
        origin = [SIMD3<Int32>](repeating: .zero, count: levels)
    }

    /// Per level: `origin = floor(camera / spacing) - size / 2`.
    package mutating func follow(camera: SIMD3<Float>) {
        for l in 0..<spacing.count {
            let f = (camera / spacing[l]).rounded(.down)
            origin[l] = SIMD3<Int32>(Int32(f.x), Int32(f.y), Int32(f.z)) &- WorldCacheGrid.size / 2
        }
    }

    /// Toroidal slot of a cell: `m = ((cell % size) + size) % size`, `m.x + 32 * (m.y + 16 * m.z)`.
    package static func slot(cell: SIMD3<Int32>) -> Int {
        let m = ((cell % size) &+ size) % size
        return Int(m.x) + 32 * (Int(m.y) + 16 * Int(m.z))
    }

    /// Inverse of `slot` within the window `origin ..< origin + size`. Port to Metal verbatim:
    ///   m = (slot % 32, (slot / 32) % 16, slot / 512)
    ///   cell = origin + (((m - origin) % size) + size) % size
    package static func cell(slot: Int, origin: SIMD3<Int32>) -> SIMD3<Int32> {
        let m = SIMD3<Int32>(Int32(slot % 32), Int32((slot / 32) % 16), Int32(slot / 512))
        return origin &+ (((m &- origin) % size) &+ size) % size
    }

    /// The slots refreshed on `frame` when a full level is refreshed over `updateFrames` frames.
    package static func updateRange(frame: UInt32, updateFrames: Int) -> (first: Int, count: Int) {
        let frames = max(updateFrames, 1)
        let count = (probesPerLevel + frames - 1) / frames
        let first = min(Int(frame % UInt32(frames)) * count, probesPerLevel)
        return (first, min(count, probesPerLevel - first))
    }
}
