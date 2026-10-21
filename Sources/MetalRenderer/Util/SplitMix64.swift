import Foundation

/// Small seeded RNG for deterministic scene generation.
package struct SplitMix64 {
    private var state: UInt64
    package init(seed: UInt64) { state = seed }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    package mutating func next() -> Float { Float(nextUInt64() >> 40) / Float(1 << 24) }
    package mutating func range(_ lo: Float, _ hi: Float) -> Float { lo + (hi - lo) * next() }
    package mutating func int(_ n: Int) -> Int { Int(nextUInt64() % UInt64(n)) }
}
