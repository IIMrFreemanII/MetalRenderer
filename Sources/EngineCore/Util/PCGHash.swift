/// The PCG hash of `v` (MSL pcgHash, Shaders/Sampling.metal): the plants' level jitter, the hair's strands. Inlinable:
/// loops in other modules call it per element.
@inlinable @inline(__always) package func pcgHash(_ v: UInt32) -> UInt32 {
    let state = v &* 747796405 &+ 2891336453
    let word = ((state >> ((state >> 28) &+ 4)) ^ state) &* 277803737
    return (word >> 22) ^ word
}
