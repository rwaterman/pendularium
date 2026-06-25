import Foundation

/// SplitMix64 — a small, fast, well-distributed PRNG. Deterministic from a seed so a
/// given `--seed` reproduces the same per-pendulum initial conditions.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform Float in [0, 1).
    mutating func float01() -> Float {
        Float(Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0))
    }

    /// Uniform Float in [lo, hi).
    mutating func float(_ lo: Float, _ hi: Float) -> Float {
        lo + float01() * (hi - lo)
    }
}

/// Derive a stable per-index seed so pendulum `i` has the same initial state regardless
/// of when (or whether) it is spawned during a run.
func pendulumSeed(base: UInt64, index: Int) -> UInt64 {
    var z = base &+ (UInt64(bitPattern: Int64(index)) &* 0x9E37_79B9_7F4A_7C15)
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}
