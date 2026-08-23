import Foundation
import simd

/// One vertex in a line buffer. Laid out to match the Metal `TrailVertex` struct
/// (`packed_float3` + `uint`), 16-byte stride. The `uint` is NOT a baked color — it packs the
/// scalars (speed, hue, angle, alpha) the shader needs to compute color for the *current* color
/// mode, so switching modes recolors the whole accumulated painting live, for free.
struct TrailVertex {
    var x: Float
    var y: Float
    var z: Float
    var attribs: UInt32

    init(_ p: SIMD3<Float>, attribs: UInt32) {
        self.x = p.x
        self.y = p.y
        self.z = p.z
        self.attribs = attribs
    }
}

/// Pack four normalized [0,1] scalars into RGBA8 byte order (byte0=speed … byte3=alpha),
/// matching the Metal unpacking. Values are clamped.
@inline(__always)
func packAttribs(speed: Float, hue: Float, angle: Float, alpha: Float) -> UInt32 {
    @inline(__always) func b(_ x: Float) -> UInt32 { UInt32(max(0, min(255, x * 255))) }
    return b(speed) | (b(hue) << 8) | (b(angle) << 16) | (b(alpha) << 24)
}

/// How trail/arm color is derived. Cycled at runtime with `C`; recolors the painting live.
/// - speed: cool→hot by instantaneous bob-2 speed (the chaotic energy distribution)
/// - identity: a per-pendulum hue baked at spawn (tracks each trajectory → divergence/mixing)
/// - phase: hue by swing angle (phase field → who is in/out of sync)
enum ColorMode: Int, CaseIterable {
    case speed, identity, phase
    var label: String {
        switch self {
        case .speed: return "speed"
        case .identity: return "identity"
        case .phase: return "phase"
        }
    }
}

/// Per-frame shader uniforms. Must match the Metal `Uniforms` struct.
struct Uniforms {
    var mvp: simd_float4x4
    var modeParams: SIMD4<Float>  // x = colorMode (as float), y,z,w spare
}

/// Per-pendulum constants, fixed at spawn.
struct PendulumRecord {
    var id: Int
    var spawnFrame: Int
    var pivot: SIMD3<Float>
    var l1, l2, m1, m2: Float
    var theta1_0, theta2_0: Float
    var hue: Float
    var energy: Float
    var twinOf: Int?
}

/// Per-pendulum state at one sampled frame.
struct StateRecord {
    var id: Int
    var theta1, theta2, omega1, omega2: Float
    var speed: Float
    var tip: SIMD3<Float>
}

/// Log lines go to stderr so `--stream` can own stdout.
func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
