import Foundation

/// All runtime tunables in one place.
struct Config {
    // Simulation
    var gravity: Float = 9.81
    var subSteps: Int = 8
    var subDt: Float = 1.0 / 480.0   // subSteps * subDt = 1/60 advanced per frame (deterministic)

    // Field layout — pivots spread across a wide, shallow-depth volume (parallel sheets in Z).
    var spreadX: Float = 46
    var spreadY: Float = 16
    var spreadZ: Float = 34
    var armBase: Float = 1.0         // base length of each of the two arms
    var armJitter: Float = 0.35      // ± fractional jitter on arm length
    var massJitter: Float = 0.4      // ± fractional jitter on bob mass

    // Color
    var speedScale: Float = 6.5      // bob-2 speed mapped to [0,1] as speed/speedScale
    var trailAlpha: Float = 0.05     // per-segment weight accumulated into the HDR target
    var armAlpha: Float = 0.5        // live arms
    var exposure: Float = 1.0        // HDR exposure before tone mapping
    var saturation: Float = 1.45     // saturation boost after tone mapping

    // Growth (grow-to-budget)
    var maxPendulums: Int = 120_000  // hard ceiling (also sizes the live-arm buffer)
    var spawnPerFrame: Int = 96      // pendulums added each frame while in the growing phase
    var frameBudgetMs: Double = 13.0 // CPU(sim) + GPU work budget; gates spawning

    // Trail memory cap → "until it can't draw any more"
    var trailMemoryMB: Int = 192     // 192 MB / 16 B ≈ 12.6M vertices ≈ 6.3M segments

    // Camera
    var cameraRadius: Float = 130
    var orbitRateRadPerSec: Float = 0.07
    var orthoHalfHeight: Float = 42  // vertical half-extent framed by the 2D orthographic view

    var trailVertexCapacity: Int { (trailMemoryMB * 1024 * 1024) / MemoryLayout<TrailVertex>.stride }
}
