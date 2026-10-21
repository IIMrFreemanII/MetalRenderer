import Foundation

/// A small seeded generator (the scene is the same every time it is built).
package struct SplitMix {
    var state: UInt64
    package init(seed: UInt64) { state = seed }
    package mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// In [0, 1).
    package mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
